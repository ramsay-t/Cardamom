defmodule Cardamom.ChainStore do
  @moduledoc """
  The forensic store facade: one clean wrapper over the durable SQLite store
  (`Store.Repo`, the truth) and the hot in-memory cache (`Store.Cache`, Nebulex).

  The long-term shape is three writers and three readers — headers, blocks, txs —
  plus the tip. THIS SLICE implements headers + tip only, which stand alone WITHOUT
  block bodies while we're trust-everything: following the chain and resuming from
  tip need only headers. Blocks and txs slot in as more tables behind the same
  facade once block-fetch (proto 3) exists — no re-architecting.

    * **writer** `put_header/1` writes to SQLite AND populates the cache (write-through);
    * **reader** `get_header/1` reads the cache, and on a miss reads through to SQLite
      and refills — so an evicted-then-queried header comes back warm.

  The cache is just a working set; SQLite is the source of truth. A cold start (or a
  full eviction) reads everything back from SQLite transparently.
  ## Fetch coordination (this process)

  ChainStore is a registered GenServer that owns a ROUND-ROBIN list of PEERS we can
  block-fetch from. Each peer is represented by its `BlockFetch.Client` — the proto-3
  mini-protocol process on that peer's bearer (`Connection`). The bearer muxes
  block-fetch over the same socket as that peer's chain-sync/keep-alive (time-division
  multiplexing — one connection per peer, many mini-protocols).

  `get_blocks/1` (public, no peer arg) pops the head peer, fetches the missing range
  against it (the request is muxed onto that peer's bearer), and rotates the list
  (`[p1,p2,p3]` → `[p2,p3,p1]`) — fair spread across peers, no scheduler, just the
  list. One peer is the one-element case (rotates to itself). Peers join via
  `register_peer/1` (e.g. Peer.Session when its block-fetch mini-protocol comes up).

  The pure STORE operations (put/get header & block, tip, read-through) are plain
  functions — Nebulex + the Ecto Repo own their own concurrency, so those need no
  process. Only the peer-list + fetch coordination lives in GenServer state.
  """

  use GenServer

  alias Cardamom.Store.{Cache, Header, Kv, Repo}
  alias Cardamom.Store.{Txo, MempoolTxo, MempoolGraveyard, MempoolTxInput}
  alias Cardamom.Ledger.Conway.Tx

  # ---- fetch-coordination process (peer round-robin) ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a peer's `BlockFetch.Client` (the proto-3 process on its bearer) into the
  round-robin rotation. Block requests are spread across registered peers; within a
  peer, the request is muxed onto its bearer alongside its other mini-protocols.
  """
  def register_peer(block_fetch_client) when is_pid(block_fetch_client),
    do: GenServer.call(__MODULE__, {:register_peer, block_fetch_client})

  @doc "Peer block-fetch clients currently in the rotation (for tests/introspection)."
  def peers, do: GenServer.call(__MODULE__, :peers)

  @doc "Clear the peer rotation (e.g. test isolation, or full peer-set reset)."
  def reset_peers, do: GenServer.call(__MODULE__, :reset_peers)

  @impl true
  def init(opts) do
    {:ok, %{peers: Keyword.get(opts, :peers, [])}}
  end

  @impl true
  def handle_call({:register_peer, client}, _from, %{peers: ps} = state) do
    {:reply, :ok, %{state | peers: ps ++ [client]}}
  end

  def handle_call(:peers, _from, state), do: {:reply, state.peers, state}

  def handle_call(:reset_peers, _from, state), do: {:reply, :ok, %{state | peers: []}}

  # Pop the head peer for a fetch and rotate it to the tail.
  def handle_call(:next_peer, _from, %{peers: []} = state),
    do: {:reply, nil, state}

  def handle_call(:next_peer, _from, %{peers: [p | rest]} = state),
    do: {:reply, p, %{state | peers: rest ++ [p]}}

  defp next_peer, do: GenServer.call(__MODULE__, :next_peer)

  # ---- headers ----

  @doc """
  Persist a DECODED header (the real ingestion path): takes a
  `Cardamom.Ledger.Conway.Header` struct and its raw bytes, mapping the forensic
  columns and the verbatim bytes together.
  """
  def put_decoded_header(%Cardamom.Ledger.Conway.Header{} = decoded, raw) when is_binary(raw) do
    put_header(Cardamom.Store.Header.from_decoded(decoded, raw))
  end

  @doc "Persist a header row (durable + cache). `h` is a map of header columns."
  def put_header(h) when is_map(h) do
    {:ok, row} =
      %Header{}
      |> Header.changeset(h)
      |> Repo.insert(
        on_conflict: :replace_all,
        conflict_target: :hash
      )

    Cache.put({:header, row.hash}, row)
    {:ok, row}
  end

  @doc "Fetch a header by hash: cache first, then read through to SQLite and refill."
  def get_header(hash) when is_binary(hash) do
    read_through({:header, hash}, fn -> Repo.get(Header, hash) end)
  end

  @doc "All headers, slot-ordered. (Durable scan — used to rebuild the in-memory forest on boot.)"
  def all_headers do
    import Ecto.Query
    Repo.all(from h in Header, order_by: [asc: h.slot])
  end

  # ---- blocks (bodies) ----

  alias Cardamom.Store.Block, as: BlockRow
  alias Cardamom.Ledger.Conway.Block, as: BlockDecode

  @doc """
  All stored blocks, slot-ordered. The durable, COMPLETE record of fetched block
  bytes (blocks.raw) — used for offline replay (decode/verify a real block without
  re-hitting the network) instead of the old truncated raw-byte log.
  """
  def all_blocks do
    import Ecto.Query
    Repo.all(from b in BlockRow, order_by: [asc: b.slot])
  end

  @doc """
  LOCAL lookup of a block by (header) hash: cache → SQLite, nil if absent. NO network
  fetch (that's get_blocks/2). The read-only "what block do we already have for H?"
  query — used internally by get_blocks and available for forensics/assertions.
  """
  def stored_block(hash) when is_binary(hash) do
    read_through({:block, hash}, fn -> Repo.get(BlockRow, hash) end)
  end

  @doc """
  Get a list of blocks for the given POINTS (`[[slot, hash], ...]`), fetching any we
  don't have. Returns a list (request order) of SELF-DESCRIBING results — each
  carries its own point/block so the caller can act without re-correlating to the
  input:

    * `{:ok, block_row}` — present (already stored, or fetched + verified + stored);
    * `{:rejected, point}` — a peer served a body that FAILED block_body_hash verify
      (a liar — "you can attach anything to a valid header"); dropped, never stored.
      The caller should STRIKE the peer for this point.
    * `{:unavailable, point}` — no peer served it (and not already stored). The
      caller should RETRY later.

  Range-aware read-through: check the local store (cache → SQLite) for ALL points
  first; group CONSECUTIVE misses into runs, ONE range `fetch_range` per run (fetch
  every miss, never re-fetch what we have, never spam N=1); verify each fetched block
  against its header's `block_body_hash` at ingest (the trust boundary) before storing.

  The fetch goes against the next channel in the ROUND-ROBIN list (popped + rotated
  via this GenServer). With no channel registered, misses are `{:unavailable, point}`.
  """
  def get_blocks(points) when is_list(points) do
    # 1. Check the local store for ALL requested points first (cache → SQLite).
    missing = Enum.reject(points, fn [_slot, hash] -> stored_block(hash) != nil end)

    # 2. Range-request the misses (consecutive runs → one range each), against the
    #    next round-robin peer. The fetch STREAMS each block to `verify_and_store` in
    #    its own process; the call blocks until the relay finished/stalled AND all
    #    those handlers committed (so the store read below isn't racing late writers).
    #    Returns :ok / {:error, _} — a completion signal, NOT the blocks themselves.
    for run <- miss_runs(missing, points) do
      fetch_range_streaming(List.first(run), List.last(run), next_peer())
    end

    # 3. Read the (now-settled) store and tag each point, in request order. Anything
    #    that didn't land (network/decode failed before completion) is :unavailable.
    Enum.map(points, fn [_slot, hash] = point ->
      case stored_block(hash) do
        nil -> {:unavailable, point}
        row -> {:ok, row}
      end
    end)
  end

  @doc """
  Fetch a single block by point. Same self-describing result as one element of
  `get_blocks/1`: `{:ok, block} | {:rejected, point} | {:unavailable, point}`.
  """
  def get_block(point) do
    [result] = get_blocks([point])
    result
  end

  # Split the missing points into runs of points that are CONSECUTIVE in the original
  # request list (so each run is a contiguous span to range-fetch in one request).
  defp miss_runs(missing, points) do
    miss_set = MapSet.new(missing, fn [_s, h] -> h end)

    points
    |> Enum.chunk_while(
      [],
      fn [_s, h] = pt, run ->
        if MapSet.member?(miss_set, h),
          do: {:cont, [pt | run]},
          else: (if run == [], do: {:cont, []}, else: {:cont, Enum.reverse(run), []})
      end,
      fn run -> (if run == [], do: {:cont, []}, else: {:cont, Enum.reverse(run), []}) end
    )
    |> Enum.reject(&(&1 == []))
  end

  # Fire a STREAMING range fetch [from..to] against `client` (a BlockFetch.Client pid),
  # with verify_and_store/1 as the per-block sink. Blocks until the fetch completes
  # (batch done or idle stall) AND all spawned block handlers have finished storing.
  # Returns :ok / {:error, _} (a completion signal — the blocks went to the store, not
  # back here). No peer in the rotation → nothing to fetch.
  defp fetch_range_streaming(_from, _to, nil), do: {:error, :no_peer}

  defp fetch_range_streaming(from, to, client) do
    result = Cardamom.BlockFetch.Client.fetch_range(client, from, to, &verify_and_store/1)

    with {:error, reason} <- result do
      require Logger
      Logger.warning("block_fetch range #{inspect(from)}..#{inspect(to)}: #{inspect(reason)}")
      {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:fetch_exit, reason}}
  end

  # The TRUST BOUNDARY: decode the block, verify its body against the header's
  # block_body_hash commitment, and only then store. A tampered/lying body is dropped
  # — and we surface its (claimed header) hash so the caller can tag that point
  # :rejected. Undecodable bytes have no usable hash → bare :rejected.
  defp verify_and_store(raw) when is_binary(raw) do
    case BlockDecode.decode(raw) do
      {:ok, blk} ->
        case BlockDecode.verify_body(blk) do
          :ok ->
            result = put_block(blk)
            # FINISH-time event: decoded + verified + stored, with real detail (the
            # UI/log shows the block landing, not just bytes arriving).
            :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{
              protocol: "block_fetch",
              msg: "BlockStored",
              block_no: blk.header.block_number,
              slot: blk.header.slot,
              tx_count: blk.tx_count
            })

            require Logger
            Logger.info("block_fetch BlockStored block_no=#{blk.header.block_number} slot=#{blk.header.slot} txs=#{blk.tx_count}")
            result

          {:error, reason} ->
            require Logger
            Logger.warning("block #{Base.encode16(blk.hash, case: :lower)} rejected: #{inspect(reason)}")
            {:rejected, blk.hash}
        end

      other ->
        require Logger
        Logger.warning("block rejected (undecodable): #{inspect(other)}")
        :rejected
    end
  end

  @doc "Persist a verified decoded block (durable + cache). Returns {:ok, row}."
  def put_block(%BlockDecode{} = blk) do
    attrs = %{
      hash: blk.hash,
      slot: blk.header.slot,
      block_no: blk.header.block_number,
      tx_count: blk.tx_count,
      raw: blk.raw
    }

    {:ok, row} =
      %BlockRow{}
      |> BlockRow.changeset(attrs)
      |> Repo.insert(on_conflict: :replace_all, conflict_target: :hash)

    Cache.put({:block, row.hash}, row)
    {:ok, row}
  end

  # ---- tip (resume point) ----

  @doc "Persist the current tip hash so a restart can resume via FindIntersect."
  def put_tip(hash) when is_binary(hash) do
    {:ok, _} =
      %Kv{}
      |> Kv.changeset(%{key: "tip", value: hash})
      |> Repo.insert(on_conflict: :replace_all, conflict_target: :key)

    Cache.put({:kv, "tip"}, hash)
    :ok
  end

  @doc """
  The resume point for chain-sync `FindIntersect`, as `[slot, hash]`, or nil if we
  have no stored tip (cold start → sync from genesis). The tip hash is the forest's
  judged best tip (`get_tip/0`); we join to its stored header for the slot.
  """
  def resume_point do
    with hash when is_binary(hash) <- get_tip(),
         %Header{slot: slot} <- get_header(hash) do
      [slot, hash]
    else
      _ -> nil
    end
  end

  @doc "The persisted tip hash, or nil if none stored yet."
  def get_tip do
    read_through({:kv, "tip"}, fn ->
      case Repo.get(Kv, "tip") do
        %Kv{value: v} -> v
        nil -> nil
      end
    end)
  end

  # ---- read-through: cache, on miss run fetch_fn, refill, return ----
  # ---- TXOs: transaction outputs (the entity that gets spent) ----

  @doc """
  Process a block's raw bytes into the TXO store: for each tx, INSERT its outputs as
  TXOs (spent_by null = unspent), and SET spent_by on the TXOs its inputs consume.

  Verdict-free and order-tolerant (like the forest): an input whose source output isn't
  in our index yet (its block not processed) simply finds no row to mark — no error. So
  spent_by reflects only what we've seen; for an observer answering "current state",
  that's correct and converges as more blocks are processed.
  """
  def process_block(raw) when is_binary(raw) do
    with {:ok, txs} <- Tx.txs_in(raw) do
      # TWO PHASES, matching the Agda block-level rule newUtxo = (utxo ∣ ins ᶜ) ∪ outs
      # computed over the WHOLE block: union ALL this block's outputs FIRST, then apply
      # ALL spends. This is what makes intra-block output→input chains correct — a tx can
      # spend an earlier tx's output because all of the block's outputs are present before
      # any spend is resolved. They are "concurrent by virtue of being in this block"
      # (Ramsay's separation sense), so the two phases may each run in any order/parallel;
      # only the phase BOUNDARY (outputs-before-spends) is ordered.
      Enum.each(txs, &create_outputs/1)
      # Phase 2 spends; collect any whose target wasn't in the store. After phase 1,
      # intra-block producers all exist, so a leftover :no_target here is a CROSS-block
      # reference we don't have (unsynced) — verdict-free/unresolved, not an error to
      # crash on. We log it so it's visible (could later feed an :unresolved record).
      unresolved = Enum.flat_map(txs, &apply_spends/1)

      if unresolved != [] do
        require Logger
        Logger.debug(fn -> "process_block: #{length(unresolved)} spend(s) had no in-store target (cross-block / unsynced)" end)
      end

      # MEMPOOL CASCADE: a block changes the UTxO set, so pending txs may now be unviable.
      # Idempotent + monotone (evictions only push toward terminal states), so this is
      # order-independent — safe under fully-parallel apply (the mailbox can pick any order).
      Enum.each(txs, &cascade_mempool/1)
      :ok
    end
  end

  # For one confirmed block tx: (1) if it was itself PENDING, it just confirmed → evict
  # :in_block; (2) every UTxO it spent invalidates the pending txs that depended on that
  # UTxO — a spender is out-competed (:inputs_spent), a referencer can no longer read it.
  defp cascade_mempool(%{txid: txid, valid: valid} = tx) do
    # The tx confirmed (promoted out of the mempool, if it was there).
    if mempool_present?(txid), do: drop_mempool_tx(txid, :in_block)

    # Which UTxOs did this tx consume? Valid → its inputs; invalid → its collateral.
    spent =
      if valid, do: Map.get(tx, :inputs, []), else: Map.get(tx, :collateral_inputs, [])

    Enum.each(spent, fn {in_txid, in_ix} ->
      mempool_spenders_of(in_txid, in_ix)
      |> Enum.map(& &1.spender_txid)
      |> Enum.uniq()
      # Don't re-evict the tx that just confirmed itself (handled above).
      |> Enum.reject(&(&1 == txid))
      |> Enum.each(fn pending -> drop_mempool_tx(pending, :inputs_spent) end)
    end)
  end

  defp mempool_present?(txid) do
    import Ecto.Query
    Repo.exists?(from m in MempoolTxo, where: m.txid == ^txid)
  end

  # PHASE 1 — outputs. Valid tx: its normal outputs become unspent TXOs. Invalid tx
  # (phase-2 fail, Agda ~503): only its collateral_return is created (NOT normal outputs).
  defp create_outputs(%{valid: true, txid: txid, outputs: outputs}) do
    outputs
    |> Enum.with_index()
    |> Enum.each(fn {out, ix} -> insert_txo(txid, ix, out) end)
  end

  defp create_outputs(%{valid: false, txid: txid, collateral_return: ret}) do
    if ret, do: insert_txo(txid, 0, ret)
  end

  # PHASE 2 — spends. Valid tx (Agda ~488): its normal inputs are spent, spent_how
  # :tx_input. Invalid tx (~503): ONLY collateral is consumed, spent_how :collateral;
  # normal inputs are NOT spent.
  # Returns the list of inputs whose target TXO wasn't in the store (cross-block /
  # unsynced — the caller treats these as unresolved, not errors).
  defp apply_spends(%{valid: true, txid: txid, inputs: inputs}) do
    spend_each(inputs, txid, :tx_input)
  end

  defp apply_spends(%{valid: false, txid: txid, collateral_inputs: collat}) do
    spend_each(collat, txid, :collateral)
  end

  defp spend_each(inputs, txid, how) do
    Enum.flat_map(inputs, fn {src_txid, src_ix} ->
      case mark_spent(src_txid, src_ix, txid, how) do
        :ok -> []
        {:error, :no_target} -> [{src_txid, src_ix}]
      end
    end)
  end

  @doc "Resolve a TXO by its (txid, ix) reference: cache → SQLite read-through, or nil."
  def txo(txid, ix) when is_binary(txid) and is_integer(ix) do
    read_through({:txo, txid, ix}, fn -> Repo.get_by(Txo, txid: txid, ix: ix) end)
  end

  @doc "The current UTXO set — all unspent TXOs (spent_by IS NULL)."
  def unspent_txos do
    import Ecto.Query
    Repo.all(from t in Txo, where: is_nil(t.spent_by))
  end

  defp insert_txo(txid, ix, out) do
    {:ok, row} =
      %Txo{}
      |> Txo.changeset(%{
        txid: txid,
        ix: ix,
        address: out.address,
        value: out.value,
        datum_hash: out.datum_hash,
        datum: encode_datum(out.datum),
        raw: out.raw,
        created_txid: txid,
        spent_by: nil
      })
      |> Repo.insert(on_conflict: :replace_all, conflict_target: [:txid, :ix])

    Cache.put({:txo, txid, ix}, row)
    {:ok, row}
  end

  @doc """
  Mark a TXO spent (spent_by + spent_how) — FAIL FAST. Returns `:ok` if the target row
  existed and was updated, `{:error, :no_target}` if it isn't in the store. We do NOT
  silently no-op or insert a placeholder: a missing target is a real condition the CALLER
  must judge with its context — an intra-block producer not yet applied (retry; it WILL
  arrive) vs a reference to a UTxO we simply don't have (a different verdict, :unresolved).
  The store op stays dumb; recovery policy lives in the handler that knows which case it is.
  spent_how: :tx_input (normal valid spend) | :collateral (phase-2-fail penalty).
  """
  def mark_spent(src_txid, src_ix, spender_txid, spent_how) do
    # A TXO is a single entity keyed (txid, ix) — look it up, spend it if present. (Not
    # an update_all-and-count-rows: that treats a known singleton as a bulk op.)
    case Repo.get_by(Txo, txid: src_txid, ix: src_ix) do
      nil ->
        {:error, :no_target}

      txo ->
        {:ok, _} =
          txo
          |> Ecto.Changeset.change(spent_by: spender_txid, spent_how: Atom.to_string(spent_how))
          |> Repo.update()

        Cache.delete({:txo, src_txid, src_ix})
        :ok
    end
  end

  # Datums are arbitrary CBOR terms; persist as bytes (re-encode the decoded term). nil
  # stays nil (no inline datum / hash-only output).
  defp encode_datum(nil), do: nil
  defp encode_datum(term), do: CBOR.encode(term)

  # ---- Mempool TXOs: PENDING outputs (separate table, identical schema) ----

  @doc """
  Add a PENDING tx's outputs to the mempool TXO table (speculative — NOT on chain). The
  table is the verdict: this never touches the confirmed `txos` table. Add/replace; the
  live mempool supports delete (unlike confirmed TXOs, which are block-only + UPSERT).
  """
  def put_mempool_tx(%{txid: txid, outputs: outputs} = tx) do
    outputs
    |> Enum.with_index()
    |> Enum.each(fn {out, ix} ->
      %MempoolTxo{}
      |> MempoolTxo.changeset(%{
        txid: txid,
        ix: ix,
        address: out.address,
        value: out.value,
        datum_hash: out.datum_hash,
        datum: encode_datum(out.datum),
        raw: out.raw,
        created_txid: txid,
        spent_by: nil
      })
      |> Repo.insert(on_conflict: :replace_all, conflict_target: [:txid, :ix])
    end)

    # Record the spend-graph EDGES: which UTxOs this pending tx depends on, and HOW. The
    # reverse index (input → spenders) drives the block→mempool cascade + separation.
    record_edges(txid, Map.get(tx, :inputs, []), "spend")
    record_edges(txid, Map.get(tx, :reference_inputs, []), "reference")
    record_edges(txid, Map.get(tx, :collateral_inputs, []), "collateral")
    :ok
  end

  defp record_edges(spender_txid, inputs, kind) do
    Enum.each(inputs, fn {in_txid, in_ix} ->
      %MempoolTxInput{}
      |> MempoolTxInput.changeset(%{
        input_txid: in_txid,
        input_ix: in_ix,
        spender_txid: spender_txid,
        kind: kind
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:input_txid, :input_ix, :spender_txid, :kind])
    end)
  end

  @doc "Pending txs that depend on UTxO (txid, ix) — the cascade/separation reverse query."
  def mempool_spenders_of(input_txid, input_ix) do
    import Ecto.Query

    Repo.all(
      from e in MempoolTxInput,
        where: e.input_txid == ^input_txid and e.input_ix == ^input_ix
    )
  end

  @doc "Resolve a PENDING TXO by (txid, ix) from the mempool table, or nil."
  def mempool_txo(txid, ix) when is_binary(txid) and is_integer(ix) do
    Repo.get_by(MempoolTxo, txid: txid, ix: ix)
  end

  @doc "Distinct txids currently in the mempool (for the TxSubmission submitter side)."
  def unspent_mempool_txids do
    import Ecto.Query
    Repo.all(from m in MempoolTxo, distinct: true, select: m.txid)
  end

  @doc """
  Evict a tx from the mempool — the TWO ways a tx legitimately LEAVES, named explicitly
  (the protocol never tells us; see reference_txsubmission_lifecycle):

    * `:in_block`    — it was included in a block (learned from block-fetch / process_block;
                       authoritative).
    * `:invalidated` — our own policy dropped it (expired, replaced, or became invalid;
                       heuristic — TxSubmission has no removal message).

  Thin wrapper over `drop_mempool_tx/2` constraining the reason to the lifecycle vocabulary.
  """
  def evict_mempool_tx(txid, reason) when is_binary(txid) and reason in [:in_block, :invalidated] do
    drop_mempool_tx(txid, reason)
  end

  @doc """
  Remove a pending tx's outputs from the live mempool (it confirmed / was replaced /
  expired), copying each to the graveyard with the reason. `reason` is an atom.
  """
  def drop_mempool_tx(txid, reason) when is_binary(txid) and is_atom(reason) do
    import Ecto.Query
    now = System.system_time(:second)
    rows = Repo.all(from m in MempoolTxo, where: m.txid == ^txid)

    for m <- rows do
      %MempoolGraveyard{}
      |> MempoolGraveyard.changeset(%{
        txid: m.txid,
        ix: m.ix,
        address: m.address,
        value: m.value,
        datum_hash: m.datum_hash,
        datum: m.datum,
        raw: m.raw,
        created_txid: m.created_txid,
        spent_by: m.spent_by,
        reason: Atom.to_string(reason),
        buried_at: now
      })
      |> Repo.insert()
    end

    Repo.delete_all(from m in MempoolTxo, where: m.txid == ^txid)
    # Remove this tx's spend-graph edges too (it no longer depends on anything).
    Repo.delete_all(from e in MempoolTxInput, where: e.spender_txid == ^txid)
    :ok
  end

  @doc "Forensic graveyard rows for a (former) mempool txid."
  def mempool_graveyard(txid) when is_binary(txid) do
    import Ecto.Query
    Repo.all(from g in MempoolGraveyard, where: g.txid == ^txid)
  end

  # nil results are NOT cached (a genuine absence shouldn't pin a negative entry —
  # the next write should be visible immediately).
  defp read_through(key, fetch_fn) do
    case Cache.get(key) do
      nil ->
        case fetch_fn.() do
          nil -> nil
          val -> Cache.put(key, val) && val
        end

      val ->
        val
    end
  end
end
