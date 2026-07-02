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
  alias Cardamom.Store.{Txo, MempoolTxo, MempoolGraveyard, MempoolTxInput, Peer, BlockGraveyard}
  alias Cardamom.Store.Cached
  import Ecto.Query

  # Cached store for the mempool spend-graph edge index, the HOTTEST read (the per-block
  # cascade asks "who spends X?" for every spent input). Caches the list of SPENDER TXIDS
  # (keys) by input — not whole rows: the list changes only when edges add/remove (clear
  # invalidation points), and each spender's row is independently cached by its own PK.
  # Resolving the spenders is then a parallel map of cheap cached lookups.
  defp edge_index do
    Cached.new_list(
      cache_tag: :mempool_edges,
      load: fn {in_txid, in_ix} ->
        Repo.all(
          from e in MempoolTxInput,
            where: e.input_txid == ^in_txid and e.input_ix == ^in_ix,
            distinct: true,
            select: e.spender_txid
        )
      end
    )
  end

  # Cached PK-keyed store for the mempool TXOs — the cache-vital read (every gossiped tx,
  # every cascade lookup hits it). Keyed (txid, ix), same shape as the confirmed txos.
  defp mempool_store do
    Cached.new(schema: MempoolTxo, cache_tag: :mempool_txo, key_fields: [:txid, :ix])
  end

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
  A cheap chain-data SUMMARY for the UI: how far body backfill has caught up with headers, and
  the UTXO-set totals. All indexed counts. The headers-vs-bodies gap (shrinking live) is the
  metronome's progress story; the txo totals are the UTxO engine's output.
  """
  def chain_summary do
    headers = Repo.aggregate(Header, :count)
    bodies = Repo.aggregate(BlockRow, :count)
    pending = Repo.aggregate(from(b in BlockRow, where: b.txo_processed == false), :count)
    txos = Repo.aggregate(Txo, :count)
    unspent = Repo.aggregate(from(t in Txo, where: is_nil(t.spent_by)), :count)

    %{
      headers: headers,
      bodies: bodies,
      gap: max(headers - bodies, 0),
      pending: pending,
      txos: txos,
      unspent: unspent,
      spent: txos - unspent
    }
  end

  @doc """
  The most recent tx-bearing blocks (for the UI feed): `[%{block_no, slot, tx_count}]`, newest
  first, up to `limit`. Empty blocks (the vast majority on early Preview) are excluded — the
  feed shows where actual transaction activity happened.
  """
  def recent_tx_blocks(limit \\ 10) do
    Repo.all(
      from b in BlockRow,
        where: b.tx_count > 0,
        order_by: [desc: b.block_no],
        limit: ^limit,
        select: %{block_no: b.block_no, slot: b.slot, tx_count: b.tx_count}
    )
  end

  @doc """
  The NEXT run of header points (`[[slot, hash], ...]`, slot-ordered, up to `limit`) whose
  block body we DON'T have yet — i.e. headers ahead of our body coverage. The metronome body-
  fetcher feeds these straight to `get_blocks/1` (which range-fetches consecutive misses). A
  LEFT JOIN headers→blocks where the block is absent; capped so one tick fetches at most one
  500-block range. Returns [] when bodies have caught up to headers.
  """
  def headers_missing_bodies(limit \\ 500) do
    import Ecto.Query

    Repo.all(
      from h in Header,
        left_join: b in BlockRow,
        on: b.hash == h.hash,
        where: is_nil(b.hash),
        order_by: [asc: h.slot],
        limit: ^limit,
        select: [h.slot, h.hash]
    )
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

            # Body-hash VERIFIED → now extract the block's transactions into the TXO /
            # mempool engine: create confirmed TXOs, spend their inputs, and run the
            # block→mempool cascade. ONLY after verification (never extract TXOs from
            # unverified bytes — Harvard boundary). Idempotent, so re-fetching a block is
            # safe. This is what feeds goal (b) — the live UTxO set + mempool — from real
            # block data.
            # Extract TXOs + complete: mark done if fully resolved, else a per-block watcher
            # marks done only when its deferred cross-block spends ALL resolve (so txo_processed
            # is truthful — every spend applied, not "retriers spawned"). A crash leaves the
            # block false → the reconciler re-derives + re-watches it.
            extract_block(blk.hash, blk.raw, blk.header.slot)

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
  The resume point for chain-sync `FindIntersect`, as `[slot, hash]`, or nil if we have no
  stored headers (cold start → sync from genesis).

  We resume from the HIGHEST STORED HEADER — the true high-water mark of what we've synced —
  NOT the forest's judged `kv` tip. The kv tip can lag the stored headers (it's updated as the
  forest connects blocks and can be left stale by a short/interrupted run), which would make us
  re-stream headers we already have from near genesis (the block-492-stale-tip bug). The stored
  headers are the authoritative record; FindIntersect from the highest one lets the relay roll us
  back safely if it happens to be off a fork.
  """
  def resume_point do
    import Ecto.Query

    case Repo.one(from h in Header, order_by: [desc: h.slot], limit: 1, select: {h.slot, h.hash}) do
      {slot, hash} when is_integer(slot) and is_binary(hash) -> [slot, hash]
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
  def process_block(raw, slot \\ nil) when is_binary(raw) do
    # A block is a CONTAINER of txs, extracted by a supervised BlockHandler (one retrier process
    # per tx; see extract_block/3 and Cardamom.Ledger.{BlockHandler,TxRetrier}). This entry keeps a
    # SYNCHRONOUS contract (mempool tests + callers that lack a real block hash assert immediately),
    # so it derives a content hash for handler keying and awaits completion via extract_block_sync.
    # Returns :ok (fully extracted) | :deferred (a tx still awaits an unstored producer → the
    # handler stays live retrying) | {:error, _} on decode failure.
    hash = :crypto.hash(:sha256, raw)

    case extract_block_sync(hash, raw, slot) do
      :ok -> :ok
      :timeout -> :deferred
      {:error, {:decode_failed, reason}} -> {:error, reason}
      {:error, _other} -> :deferred
    end
  end

  @doc """
  Extract a block's TXOs ASYNCHRONOUSLY: spawn a supervised, hash-registered
  `Cardamom.Ledger.BlockHandler` that owns one retrier process per tx (create outputs, then apply
  spends, RETRYING continuously until any not-yet-stored producer arrives). The handler marks the
  block `txo_processed=true` itself ONLY when EVERY tx completes — a continuous-retry block can
  never complete synchronously, so this returns `:ok` immediately. The block BYTES are already
  durable (put_block, called by verify_and_store BEFORE this), so a crash simply leaves
  txo_processed=false and the reconciler re-spawns the handler on boot. Dedupes by hash: re-calling
  for a block whose handler is still live is a no-op. Used by the live ingest path, the reconciler,
  and tests (via extract_block_sync/4 to await completion). `hash` is the block's (header) hash.
  """
  def extract_block(hash, raw, slot \\ nil) when is_binary(hash) and is_binary(raw) do
    {:ok, _pid} = Cardamom.Ledger.BlockSupervisor.start_block(hash, raw, slot)
    :ok
  end

  @doc """
  TEST/synchronous helper: extract a block and BLOCK until its handler finishes. Monitors the
  handler pid — it exits :normal only AFTER mark_txo_processed (fully done), so a `:DOWN :normal`
  means "every tx resolved". Returns `:ok` (done), `{:error, reason}` (handler crashed), or
  `:timeout` (still retrying an absent producer — correct production behaviour, but bounded here so
  a test can't hang on a continuous retrier). NOT used on the live async path.
  """
  def extract_block_sync(hash, raw, slot \\ nil, timeout \\ 5_000)
      when is_binary(hash) and is_binary(raw) do
    {:ok, pid} = Cardamom.Ledger.BlockSupervisor.start_block(hash, raw, slot)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        :timeout
    end
  end

  @doc "Flag a stored block's TXO extraction as complete (recovery ledger)."
  def mark_txo_processed(hash) when is_binary(hash) do
    import Ecto.Query
    Repo.update_all(from(b in BlockRow, where: b.hash == ^hash), set: [txo_processed: true])
    Cache.delete({:block, hash})
    :ok
  end

  @doc """
  Reset a stored block's txo_processed flag so the reconciler RE-EXTRACTS it. Called when a
  header (re)streams past (RollForward): the header is the source of truth, so a re-seen header
  invalidates any stale "done" state — a block whose txos were wiped (bad rollback) rebuilds. If
  we don't have the block yet, update_all matches nothing (a no-op) and the metronome fetches it
  normally. Re-extraction is idempotent (insert_txo on_conflict: :nothing preserves spend state).
  """
  def mark_block_unprocessed(hash) when is_binary(hash) do
    import Ecto.Query
    Repo.update_all(from(b in BlockRow, where: b.hash == ^hash), set: [txo_processed: false])
    Cache.delete({:block, hash})
    :ok
  end

  @doc """
  CRASH/RESTART BACKSTOP: re-SPAWN a BlockHandler for every stored block still txo_processed=false
  (a handler that died with the VM, or a block interrupted mid-extraction). This is NOT the
  steady-state retry — a live handler retries its own deferred spends continuously; this only
  re-establishes handlers lost to a crash. extract_block dedupes by hash, so re-spawning a block
  whose handler is still live is a harmless no-op. The block's `raw` is already durable, so this is
  a free idempotent replay. Run on boot AND periodically. Returns the count re-spawned.
  """
  def reconcile_unprocessed_blocks(limit \\ 1_000) do
    import Ecto.Query

    pending =
      Repo.all(
        from b in BlockRow,
          where: b.txo_processed == false,
          order_by: [asc: b.slot],
          limit: ^limit,
          select: {b.hash, b.raw, b.slot}
      )

    Enum.each(pending, fn {hash, raw, slot} ->
      # Ensure a handler exists for this pending block (no-op if one is already live). ASYNC — the
      # handler marks done when its txs all resolve; the reconciler doesn't wait.
      extract_block(hash, raw, slot)
    end)

    length(pending)
  end

  @doc """
  Mempool cascade for one confirmed block tx (called by BlockHandler at spawn time): (1) if it was
  itself PENDING, it just confirmed → evict :in_block; (2) every UTxO it spent invalidates the
  pending txs that depended on that UTxO — a spender is out-competed (:inputs_spent), a referencer
  can no longer read it. Idempotent + monotone → order-independent, safe to run before spends resolve.
  """
  def cascade_mempool(%{txid: txid, valid: valid} = tx) do
    # The tx confirmed (promoted out of the mempool, if it was there).
    if mempool_present?(txid), do: drop_mempool_tx(txid, :in_block)

    # Which UTxOs did this tx consume? Valid → its inputs; invalid → its collateral.
    spent =
      if valid, do: Map.get(tx, :inputs, []), else: Map.get(tx, :collateral_inputs, [])

    # mempool_spenders_of returns SPENDER TXIDS (keys); evict each. Redundant evictions
    # are harmless (drop_mempool_tx is idempotent — a tx already gone is a no-op), so we
    # don't defensively dedup: the BEAM way is to accept redundant work, not guard it.
    # Skipping the just-confirmed tx is a cheap correctness nicety, not a safety need.
    Enum.each(spent, fn {in_txid, in_ix} ->
      mempool_spenders_of(in_txid, in_ix)
      |> Enum.reject(&(&1 == txid))
      |> Enum.each(fn pending -> drop_mempool_tx(pending, :inputs_spent) end)
    end)
  end

  defp mempool_present?(txid) do
    Repo.exists?(from m in MempoolTxo, where: m.txid == ^txid)
  end

  # NOTE: the per-tx UTxO logic (create outputs / apply spends, incl. the collateral-return-at-
  # index-length(outputs) rule) now lives in Cardamom.Ledger.TxHandler, driven per-tx by
  # Cardamom.Ledger.Container. insert_txo/mark_spent below are the storage primitives it calls.

  @doc "Resolve a TXO by its (txid, ix) reference: cache → SQLite read-through, or nil."
  def txo(txid, ix) when is_binary(txid) and is_integer(ix) do
    read_through({:txo, txid, ix}, fn -> Repo.get_by(Txo, txid: txid, ix: ix) end)
  end

  @doc "The current UTXO set — all unspent TXOs (spent_by IS NULL)."
  def unspent_txos do
    import Ecto.Query
    Repo.all(from t in Txo, where: is_nil(t.spent_by))
  end

  @doc """
  Phase-1 (structural/ledger) validation — the subset we can do WITHOUT protocol params,
  signature checks, or slot tracking. Each check is a Conway UTxO-rule precondition (Agda
  Utxo.lagda.md ~544-546):

    * txIns ≢ ∅                    — must spend something
    * txIns ∩ refInputs ≡ ∅        — can't spend AND reference the same UTxO
    * coin mint ≡ 0                — ADA cannot be minted
    * (no double-spend)            — an input already spent in our CONFIRMED set
    * txIns ∪ refInputs ⊆ dom utxo — inputs/refs must exist (resolved against our view)

  Returns `:ok` | `{:rejected, reason}` (definitely bad) | `{:unverifiable, missing}` (an
  input/ref we haven't synced — NOT the peer's fault; the caller must not penalise). The
  unresolved case is distinguished from rejection because our UTxO view is incomplete by
  design (observer): missing ≠ invalid.
  """
  def validate_tx_phase1(%{inputs: inputs, reference_inputs: refs} = tx) do
    cond do
      inputs == [] ->
        {:rejected, :no_inputs}

      not MapSet.disjoint?(MapSet.new(inputs), MapSet.new(refs)) ->
        {:rejected, :spend_reference_overlap}

      mints_ada?(Map.get(tx, :mint)) ->
        {:rejected, :mint_ada}

      true ->
        resolve_inputs(inputs, refs)
    end
  end

  # Resolve every input + reference input against our confirmed set. An input that exists
  # but is SPENT → double-spend (rejected). One we don't have → unverifiable (collect).
  defp resolve_inputs(inputs, refs) do
    spent = for {t, i} <- inputs, (r = txo(t, i)) && r.spent_by != nil, do: {t, i}
    missing = for {t, i} <- inputs ++ refs, txo(t, i) == nil, do: {t, i}

    cond do
      spent != [] -> {:rejected, {:double_spend, spent}}
      missing != [] -> {:unverifiable, missing}
      true -> :ok
    end
  end

  # mint (key 9) is a multiasset map keyed by policy id; ADA (the empty/ada policy) must
  # not appear. A bare integer or a non-empty ada entry is illegal ADA minting. We reject
  # any mint that carries a plain coin (the conservative, spec-aligned check: coin mint ≡ 0).
  defp mints_ada?(nil), do: false
  defp mints_ada?(0), do: false
  defp mints_ada?(n) when is_integer(n), do: n != 0
  defp mints_ada?(_other), do: false

  @doc """
  Storage primitive: create one TXO (txid, ix) as unspent. on_conflict: :nothing preserves an
  existing row's spend state (re-extraction is idempotent). Called by Cardamom.Ledger.TxHandler.
  """
  def insert_txo(txid, ix, out, slot) do
    attrs = %{
      txid: txid,
      ix: ix,
      address: out.address,
      value: out.value,
      datum_hash: out.datum_hash,
      datum: encode_datum(out.datum),
      raw: out.raw,
      created_txid: txid,
      created_slot: slot,
      spent_by: nil
    }

    # On conflict, DO NOTHING — insert the output if it's not already there; if it is, leave the
    # existing row completely untouched. A UTxO's creation fields (address/value/datum/raw) are
    # IMMUTABLE — the block that created it always creates the same output — so there's nothing to
    # update. Critically this means re-extracting a block (header-triggered re-load) can NEVER
    # clobber an already-SPENT output's spend state: :replace_all would reset spent_by → nil and
    # silently un-spend it (data corruption); :nothing can't touch it. This is "insert, ignore if
    # it exists" — the honest expression of "creation is idempotent, spends are separate".
    {:ok, _} =
      %Txo{}
      |> Txo.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:txid, :ix])

    # on_conflict: :nothing returns a struct WITHOUT the DB row's real state on a conflict, so
    # don't trust its :spent_by etc. — just invalidate the cache so the next read re-reads SQLite.
    Cache.delete({:txo, txid, ix})
    :ok
  end

  @doc """
  Seed a GENESIS UTXO into the confirmed `txos` table: an initial-funds output that
  exists in the genesis ledger state, not in any block body (so no block produces it).
  Chain blocks spend these (e.g. Preview block 3 spends the Byron 30B-ADA genesis UTXO),
  so they must be present BEFORE block ingestion for those spends to resolve.

  Same store shape as `insert_txo/3` — UPSERT on (txid, ix) so re-seeding on reboot is
  idempotent. Genesis outputs carry only an address + value (no datum/datum_hash). The
  output's `created_txid` is the genesis pseudo-txid itself (it has no producing tx).
  Returns `{:ok, row}`.
  """
  def insert_genesis_utxo(txid, ix, address, value)
      when is_binary(txid) and is_integer(ix) and is_binary(address) and is_integer(value) do
    {:ok, row} =
      %Txo{}
      |> Txo.changeset(%{
        txid: txid,
        ix: ix,
        address: address,
        value: value,
        datum_hash: nil,
        datum: nil,
        raw: nil,
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
  def mark_spent(src_txid, src_ix, spender_txid, spent_how, slot \\ nil) do
    # A TXO is a single entity keyed (txid, ix) — look it up, spend it if present. (Not
    # an update_all-and-count-rows: that treats a known singleton as a bulk op.) `slot` is the
    # SPENDING block's slot, stamped as spent_slot so a rollback past it can resurrect this UTXO.
    case Repo.get_by(Txo, txid: src_txid, ix: src_ix) do
      nil ->
        {:error, :no_target}

      txo ->
        {:ok, _} =
          txo
          |> Ecto.Changeset.change(
            spent_by: spender_txid,
            spent_how: Atom.to_string(spent_how),
            spent_slot: slot
          )
          |> Repo.update()

        Cache.delete({:txo, src_txid, src_ix})
        :ok
    end
  end

  @doc """
  ROLLBACK the confirmed chain to `slot` (a reorg: the relay told us to roll back, a fork won).
  Everything ABOVE `slot` is undone, in the order that keeps the UTxO set correct:

    1. RESURRECT spent UTXOs whose SPEND was above the point — `spent_slot > slot` → back to
       unspent (spent_by/spent_how/spent_slot → nil). The spend happened in a now-orphaned block,
       so the UTXO is live again. (Ramsay's "spent UTXOs especially" — the resurrection case.)
    2. DELETE outputs created above the point — `created_slot > slot` → they never existed on the
       winning chain.
    3. GRAVEYARD the orphaned blocks (slot > point) — move them out of `blocks` for forensics,
       and mark them txo-unprocessed is moot (they're gone). Their headers stay (the forest
       prunes its own view via Forest.Server.rollback).

  Ordering matters: resurrect (1) BEFORE delete (2) — a UTXO created below P but spent above P
  must be resurrected, not deleted; a UTXO created above P is deleted regardless of its spend.
  Then caches for touched rows are cleared. Idempotent: rolling back to the same point twice is a
  no-op (nothing left above it). Returns the count of {resurrected, deleted, graveyarded}.
  """
  def rollback(slot) when is_integer(slot) do
    # 0. TERMINATE live BlockHandlers for orphaned blocks (slot > point) FIRST. Each handler's
    #    ordered shutdown kills its tx retriers, CONFIRMS them dead, then cleans its own block's
    #    UTXOs (kill-confirm-then-clean — see Cardamom.Ledger.BlockHandler). terminate_block is
    #    SYNCHRONOUS, so on return every orphaned handler's per-block cleanup has committed and NO
    #    retrier can still be writing. The bulk sweep below is then a safe idempotent backstop for
    #    orphaned blocks that had no live handler (already-completed ones).
    terminate_orphaned_handlers(slot)

    # 1. RESURRECT: un-spend UTXOs whose spend was in a rolled-back block.
    {resurrected, _} =
      Repo.update_all(
        from(t in Txo, where: not is_nil(t.spent_slot) and t.spent_slot > ^slot),
        set: [spent_by: nil, spent_how: nil, spent_slot: nil]
      )

    # 2. DELETE: outputs created in a rolled-back block never happened.
    {deleted, _} = Repo.delete_all(from t in Txo, where: not is_nil(t.created_slot) and t.created_slot > ^slot)

    # 3. GRAVEYARD: move orphaned blocks out of the live set, recording what we rolled back to.
    orphaned = Repo.all(from b in BlockRow, where: b.slot > ^slot)

    Enum.each(orphaned, fn b ->
      %BlockGraveyard{}
      |> BlockGraveyard.changeset(%{
        hash: b.hash,
        slot: b.slot,
        block_no: b.block_no,
        tx_count: b.tx_count,
        raw: b.raw,
        rolled_back_to_slot: slot
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: :hash)

      Cache.delete({:block, b.hash})
    end)

    graveyarded = Repo.delete_all(from b in BlockRow, where: b.slot > ^slot) |> elem(0)

    # The TXO cache holds individual rows by (txid, ix); the bulk resurrect/delete above bypassed
    # it, so clear the cache wholesale to avoid serving stale spent/exists state after a rollback.
    # (A rollback is rare; a full cache clear is cheap and unambiguous vs. tracking touched keys.)
    Cache.delete_all()

    require Logger
    Logger.info("rollback to slot #{slot}: resurrected #{resurrected}, deleted #{deleted}, graveyarded #{graveyarded} block(s)")
    {:ok, %{resurrected: resurrected, deleted: deleted, graveyarded: graveyarded}}
  end

  # Terminate every live BlockHandler whose block is orphaned (slot > point). Each termination is
  # synchronous and runs that handler's own kill-confirm-then-clean. Blocks with no live handler
  # (already-completed) are left to the bulk sweep in rollback/1.
  defp terminate_orphaned_handlers(slot) do
    import Ecto.Query

    Repo.all(from b in BlockRow, where: b.slot > ^slot, select: b.hash)
    |> Enum.each(&Cardamom.Ledger.BlockSupervisor.terminate_block/1)
  rescue
    _ -> :ok
  end

  @doc """
  Clean ONE block's DB effects — called by a `Cardamom.Ledger.BlockHandler` in its terminate/2
  AFTER it has killed and CONFIRMED-DEAD its tx retriers (so no retrier can still write). Resurrect
  the UTXOs this block spent (spent_slot == slot → nil) and delete the outputs it created
  (created_slot == slot). All writes go through the single-connection Ecto pool, which serialises
  this cleanup after any write a now-dead retrier already enqueued. Scoped by slot (a block's txos
  all carry its slot); the block's hash is logged for traceability.
  """
  def rollback_block(hash, slot) when is_binary(hash) and is_integer(slot) do
    import Ecto.Query

    {resurrected, _} =
      Repo.update_all(
        from(t in Txo, where: t.spent_slot == ^slot),
        set: [spent_by: nil, spent_how: nil, spent_slot: nil]
      )

    {deleted, _} = Repo.delete_all(from t in Txo, where: t.created_slot == ^slot)
    Cache.delete_all()

    require Logger
    Logger.info("rollback_block #{Base.encode16(hash, case: :lower) |> binary_part(0, 8)} slot=#{slot}: resurrected #{resurrected}, deleted #{deleted}")
    :ok
  rescue
    e ->
      require Logger
      Logger.warning("rollback_block failed: #{inspect(e)}")
      :ok
  end

  def rollback_block(_hash, nil), do: :ok

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
      row =
        MempoolTxo.changeset(%MempoolTxo{}, %{
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
        |> Ecto.Changeset.apply_changes()

      # Write-through: insert + cache (so the cache-vital mempool read is warm).
      {:ok, _} = Cached.put(mempool_store(), row)
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

      # This input's spender list changed → drop its cached entry.
      Cached.invalidate_key(edge_index(), {in_txid, in_ix})
    end)
  end

  @doc "Pending txs that depend on UTxO (txid, ix) — the cascade/separation reverse query."
  def mempool_spenders_of(input_txid, input_ix) do
    Cached.get_list(edge_index(), {input_txid, input_ix})
  end

  @doc "Resolve a PENDING TXO by (txid, ix) — cache → SQLite read-through."
  def mempool_txo(txid, ix) when is_binary(txid) and is_integer(ix) do
    Cached.get(mempool_store(), {txid, ix})
  end

  @doc "Distinct txids currently in the mempool (for the TxSubmission submitter side)."
  def unspent_mempool_txids do
    import Ecto.Query
    Repo.all(from m in MempoolTxo, distinct: true, select: m.txid)
  end

  @doc """
  Evict a tx from the mempool — the TWO ways a tx legitimately LEAVES, named explicitly
  (the protocol never tells us; see reference_txsubmission_lifecycle):

    * `:in_block`     — included in a block as VALID (learned from block-fetch; authoritative).
    * `:invalid`      — included but FAILED phase-2 (collateral taken).
    * `:inputs_spent` — a conflicting tx spent its inputs first; out-competed, NOT at fault.
    * `:expired`      — its validity interval (ttl) passed (future; needs slot tracking).
    * `:rejected`     — phase-1 fail on ingest; never really entered the mempool.

  (TxSubmission has no removal message, so exit is inferred — see
  reference_txsubmission_lifecycle / project_cardamom_tx_lifecycle.) Thin wrapper over
  `drop_mempool_tx/2` constraining the reason to the lifecycle vocabulary.
  """
  def evict_mempool_tx(txid, reason)
      when is_binary(txid) and reason in [:in_block, :invalid, :inputs_spent, :expired, :rejected] do
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

    # Invalidate the mempool_txo cache entry for each output we're removing.
    Enum.each(rows, fn m -> Cached.invalidate(mempool_store(), {m.txid, m.ix}) end)
    Repo.delete_all(from m in MempoolTxo, where: m.txid == ^txid)

    # Invalidate the edge-cache entry for each input this tx touched (its spender list
    # changed), THEN remove its edges. (Read the inputs before deleting.)
    Repo.all(from e in MempoolTxInput, where: e.spender_txid == ^txid, select: {e.input_txid, e.input_ix})
    |> Enum.uniq()
    |> Enum.each(&Cached.invalidate_key(edge_index(), &1))

    Repo.delete_all(from e in MempoolTxInput, where: e.spender_txid == ^txid)
    :ok
  end

  @doc "Forensic graveyard rows for a (former) mempool txid."
  def mempool_graveyard(txid) when is_binary(txid) do
    import Ecto.Query
    Repo.all(from g in MempoolGraveyard, where: g.txid == ^txid)
  end

  # ---- Peers: reputation, on the shared Repo (peers belong to THIS chain — same magic,
  # ---- same DB — so they are chain data like everything else, not a separate store).

  # event -> quality delta. The relative ORDER is the contract (good raises, failures
  # lower, a protocol violation or invalid-tx gossip costs most). Unknown events: neutral 0
  # but still register the peer (so a network-discovered candidate becomes known).
  @peer_deltas %{
    connected: 5,
    clean_close: 3,
    served: 2,
    peer_shared: 0,
    disconnect: -3,
    timeout: -5,
    sent_invalid_tx: -10,
    sent_undecodable_tx: -10,
    protocol_violation: -25
  }

  @doc """
  Record an observation about a peer `%{host:, port:, event:}`, moving its `quality` by the
  event's delta (and registering it if new). This is how reputation MEANS something — good
  behaviour raises rank, misbehaviour (incl. gossiping invalid txs) lowers it. The trust
  layer (eclipse-resistance) will sit on top of this score.
  """
  def record_peer(%{host: host, port: port, event: event}) do
    delta = Map.get(@peer_deltas, event, 0)
    now = System.system_time(:second)
    base = (Repo.get_by(Peer, host: host, port: port) || %Peer{quality: 0}).quality || 0

    {:ok, _} =
      %Peer{}
      |> Peer.changeset(%{
        host: host,
        port: port,
        quality: base + delta,
        last_event: Atom.to_string(event),
        last_seen: now
      })
      |> Repo.insert(
        on_conflict: [set: [quality: base + delta, last_event: Atom.to_string(event), last_seen: now]],
        conflict_target: [:host, :port]
      )

    :ok
  end

  @doc "Known peers, ranked best-quality-first (hot-start dial order)."
  def known_peers do
    Repo.all(from p in Peer, order_by: [desc: p.quality])
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
