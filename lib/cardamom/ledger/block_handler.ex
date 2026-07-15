defmodule Cardamom.Ledger.BlockHandler do
  @moduledoc """
  The CONTAINER handler for one block (and, identically, a Leios Endorser Block — just bigger). A
  GenServer that traps exits, registered by block hash in `Cardamom.Ledger.BlockRegistry`, owning
  one `Cardamom.Ledger.TxRetrier` process per tx.

  THE BLOCK VALIDATION GATE (mirrors `Cardamom.Ledger.HeaderHandler`'s decode → VALIDATE → store):
  the pipeline is decode → BUILD delta + check results → VERDICT → commit. The block's ledger ops
  and their check results are built FIRST; `Cardamom.Ledger.Verdict` renders the decision; only
  an ACCEPT commits (apply the delta, spawn the tx retriers, and eventually mark_txo_processed).
  A REJECT stops `{:validation_rejected, summary}` — nothing committed, `txo_processed` stays
  false (the reconciler re-hits it and re-alarms: a self-announcing stop point), and a sync
  caller (`extract_block_sync` — the replay driver) receives the rejection as its error. On real
  chain data a reject is an ASSERTION FAILURE — expected never to fire; when it fires we stop and
  fix our code, or we've found a spec divergence. See `Cardamom.Ledger.Verdict` for the policy.

  Value conservation is the one check that CANNOT run at the gate: it needs every input resolved,
  which cross-block/out-of-order arrival only guarantees after the retriers finish. So each
  retrier reports its tx's conservation result with `{:tx_done, pid, txid, result}`; the verdict
  is finalised when the LAST tx completes, and a conservation violation rejects the block THERE —
  after its spent-markers landed (those are verdict-free graph facts, idempotent under
  re-extraction) but before the block is marked processed.

  DONE = every tx retrier reported done AND the final verdict accepts. Only THEN do we
  `mark_txo_processed` and stop :normal. A retrier crash (non-:normal :DOWN) stops us non-normally,
  leaving txo_processed=false for the reconciler crash-backstop to re-spawn us later. A retrier
  retries CONTINUOUSLY (no timeout), so a handler for a block with a not-yet-ingested producer
  stays alive, retrying, until the producer arrives — or until a rollback terminates us.

  ROLLBACK / CANCELLATION (the invariant this module exists to get right): when the owning block is
  orphaned, `ChainStore.rollback/1` terminates us. Our `terminate/2` then, IN ORDER:
    1. KILLS every still-live tx retrier,
    2. CONFIRMS each is dead (collects a :DOWN per child — Process.exit is async),
    3. ONLY THEN cleans this block's DB effects (via ChainStore, the single writer).
  Step 2 before step 3 is mandatory: a straggler retrier's in-flight insert_txo/mark_spent would
  otherwise land AFTER the cleanup and re-corrupt the DB. See [[project_cardamom_sync_model]].
  """

  use GenServer
  require Logger

  alias Cardamom.Ledger.{BlockRegistry, TxRetrier, Verdict}
  alias Cardamom.ChainStore

  # Bound on await_all_down so a wedged kill can't hang rollback (child shutdown budget is 10s).
  @down_wait_ms 5_000

  def start_link({hash, _raw, _slot} = arg) when is_binary(hash) do
    GenServer.start_link(__MODULE__, arg, name: {:via, Registry, {BlockRegistry, hash}})
  end

  @impl true
  def init({hash, raw, slot}) do
    Process.flag(:trap_exit, true)
    {:ok, %{hash: hash, raw: raw, slot: slot, pending: %{}, verdict: nil}, {:continue, :spawn_children}}
  end

  @impl true
  def handle_continue(:spawn_children, %{hash: hash, raw: raw, slot: slot} = st) do
    case Cardamom.Ledger.Block.txs_in(raw) do
      {:ok, txs} ->
        # THE GATE: build this block's ledger delta AND its check results, render the verdict,
        # and only apply on accept. (Empty blocks go through too — they can still cross an epoch
        # boundary, and boundary blocks are often empty.)
        {ops, results} = build_ledger_delta(hash, slot, txs)
        verdict = Verdict.add_all(Verdict.new(hash, slot), results)

        case Verdict.decision(verdict) do
          :reject ->
            Verdict.emit(verdict)
            {:stop, {:validation_rejected, Verdict.summary(verdict)}, st}

          :accept ->
            apply_ledger_delta(hash, slot, ops)
            continue_extraction(txs, %{st | verdict: verdict})
        end

      {:error, reason} ->
        # Undecodable body — leave txo_processed=false; don't loop. Stop non-normal (no cleanup).
        {:stop, {:decode_failed, reason}, st}
    end
  end

  # Empty block: no txs to extract and no conservation to await — the verdict is already final.
  defp continue_extraction([], st) do
    finish(st)
  end

  defp continue_extraction(txs, st) do
    me = self()

    pending =
      Map.new(txs, fn tx ->
        {pid, ref} = spawn_monitor(fn -> TxRetrier.run(me, tx, st.slot) end)
        {pid, ref}
      end)

    # MEMPOOL CASCADE: a confirmed block evicts pending mempool txs it out-competes. Idempotent
    # + monotone (evictions only push toward terminal states), order-independent — safe to run
    # at spawn time regardless of whether every UTxO chain has resolved yet.
    Enum.each(txs, &ChainStore.cascade_mempool/1)

    {:noreply, %{st | pending: pending}}
  end

  # The final decision point, once every check result is in: accept commits the processed flag;
  # reject parks the block unprocessed and surfaces the verdict as the exit reason.
  defp finish(%{verdict: verdict} = st) do
    case Verdict.decision(verdict) do
      :accept ->
        ChainStore.mark_txo_processed(st.hash)
        Verdict.emit(verdict)
        {:stop, :normal, st}

      :reject ->
        Verdict.emit(verdict)
        {:stop, {:validation_rejected, Verdict.summary(verdict)}, st}
    end
  end

  # Build this block's ledger delta (once) as `{ops, results}`, in order:
  #
  #   1. EPOCH TRANSITION ops, when this block's epoch is beyond :epoch/:last_epoch — the spec's
  #      NEWEPOCH fires on the first block of the new epoch BEFORE that block's own effects, and
  #      it must read the PRE-block state (feeSS = fees before this block's fees accrue).
  #   2. This block's FEE accrual (Σ tx fees into the :fees pot — the reward pot's fee half).
  #   3. Per tx, spec order (CERTS = PRE-CERT then the cert list, Certs.lagda.md:632-633):
  #      withdrawals (checked + zeroed, results collected) BEFORE that tx's certs.
  #
  # Every op after the first is built over Delta.read_through of the ops before it, so a captured
  # `old` reflects the same block's earlier ops (epoch ops, or an earlier cert touching the same
  # key) — reading the store directly here would capture stale values and break the journal's
  # invertibility.
  #
  # A CRASH in delta building must not fail block ingest (best-effort as ever): it degrades to
  # {no ops, one :ledger_delta_build SKIP result} — visible in the verdict, never a reject.
  #
  # ORDERING ASSUMPTION (recorded, not enforced): deltas assume blocks apply in slot order. Live
  # chain-sync delivers in order; body BACKFILL can extract out of order, where a cert/epoch op
  # could capture a wrong old value. The conformance checks are the drift alarm for this.
  defp build_ledger_delta(hash, slot, txs) do
    base_read = fn dom, key -> ChainStore.ledger_read(dom, key) end
    pp = ChainStore.protocol_deposits()

    epoch_ops = epoch_transition_ops(hash, slot, base_read)

    fee_ops =
      case Enum.reduce(txs, 0, fn tx, acc -> acc + tx_fee(tx) end) do
        0 -> []
        fees -> [{:add, :fees, :pot, fees}]
      end

    Enum.reduce(txs, {epoch_ops ++ fee_ops, []}, fn tx, {ops, results} ->
      read = Cardamom.Ledger.Delta.read_through(ops, base_read)

      {w_ops, w_results} =
        Cardamom.Ledger.WithdrawalEffects.effects(Map.get(tx, :withdrawals, []), read)

      w_results = Enum.map(w_results, fn {rule, outcome, opts} ->
        {rule, outcome, Keyword.put(opts, :txid, Map.get(tx, :txid))}
      end)

      ops = ops ++ w_ops

      cert_ops =
        tx
        |> Map.get(:certs)
        |> Cardamom.Ledger.Conway.Cert.decode_all()
        |> Enum.reduce(ops, fn cert, acc ->
          read2 = Cardamom.Ledger.Delta.read_through(acc, base_read)
          acc ++ Cardamom.Ledger.CertEffects.effects(cert, read2, pp)
        end)

      {cert_ops, results ++ w_results}
    end)
  rescue
    e ->
      Logger.warning("block #{short(hash)}: ledger-delta build failed: #{inspect(e)}")
      {[], [{:ledger_delta_build, {:skip, {:build_crashed, inspect(e)}}, []}]}
  end

  # Journal + apply an accepted block's delta. ledger_apply_block dedupes by slot (on_conflict
  # :nothing), so a re-extracted block doesn't re-journal. Best-effort — a ledger-state hiccup
  # must not fail block ingest.
  defp apply_ledger_delta(_hash, _slot, []), do: :ok

  defp apply_ledger_delta(hash, slot, ops) do
    ChainStore.ledger_apply_block(hash, slot, ops)
    :ok
  rescue
    e -> Logger.warning("block #{short(hash)}: ledger-delta apply failed: #{inspect(e)}")
  end

  # NEWEPOCH check, cheap path first: one :epoch/:last_epoch read per block; the full ledger
  # image + UTxO fold load only when a boundary is actually crossed (or on the very first block).
  # A slot-less block (test/mempool callers) can't be placed in an epoch — no transition.
  defp epoch_transition_ops(_hash, nil, _read), do: []

  defp epoch_transition_ops(hash, slot, read) do
    epoch = Cardamom.Ledger.Epoch.of(slot)

    case read.(:epoch, :last_epoch) do
      # First block ever: just record the epoch — no prior epoch to close, no loads needed.
      nil ->
        [{:set, :epoch, :last_epoch, nil, epoch}]

      last when epoch > last ->
        {ops, _state} =
          Cardamom.Ledger.EpochTransition.ops(
            ChainStore.epoch_ledger_state(),
            epoch,
            Cardamom.Ledger.EpochTransition.live_deps(hash)
          )

        ops

      _same_or_behind ->
        []
    end
  end

  # A decoded tx's fee (body key 2) — nil/malformed counts 0 (fee is also cross-checked by the
  # value-conservation oracle, so a silently-wrong fee shows up as divergence, not nothing).
  defp tx_fee(tx) do
    case Map.get(tx, :fee) do
      f when is_integer(f) and f >= 0 -> f
      _ -> 0
    end
  end

  @impl true
  def handle_info({:tx_done, pid, txid, conservation}, %{pending: pending} = st) do
    {ref, rest} = Map.pop(pending, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    st = %{st | pending: rest, verdict: add_conservation(st.verdict, txid, conservation)}

    if map_size(rest) == 0 do
      # EVERY tx completed → every check result is in → render the final verdict.
      finish(st)
    else
      {:noreply, st}
    end
  end

  # A retrier exited normally AFTER we already handled its {:tx_done} (ref demonitored+flushed), or
  # a benign race — drop it.
  def handle_info({:DOWN, _ref, :process, pid, :normal}, %{pending: pending} = st) do
    {:noreply, %{st | pending: Map.delete(pending, pid)}}
  end

  # A retrier CRASHED (not a completion). The block isn't done; stop non-normal so txo_processed
  # stays false and the reconciler re-spawns us. (terminate/2 for a non-:shutdown reason does NOT
  # clean the DB — the outputs/spends applied so far are valid and will be reused on re-extract.)
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{pending: pending} = st) do
    if Map.has_key?(pending, pid) do
      Logger.warning("block #{short(st.hash)}: tx retrier crashed: #{inspect(reason)}")
      {:stop, {:tx_crashed, reason}, st}
    else
      {:noreply, st}
    end
  end

  # Fold one tx's conservation result into the verdict (the retrier's report — see moduledoc for
  # why conservation is checked post-resolution, not at the gate).
  defp add_conservation(verdict, txid, :ok),
    do: Verdict.add(verdict, :value_conservation, :pass, txid: txid)

  defp add_conservation(verdict, txid, {:skip, reason}),
    do: Verdict.add(verdict, :value_conservation, {:skip, reason}, txid: txid)

  defp add_conservation(verdict, txid, {:diverge, detail}),
    do: Verdict.add(verdict, :value_conservation, {:violation, detail}, txid: txid)

  # ---- terminate: the ordered kill-confirm-then-clean ----

  # Fully done: children already gone, DB is correct — nothing to clean.
  @impl true
  def terminate(:normal, _st), do: :ok

  # Decode failure / retrier crash / VALIDATION REJECT: leave the partial (valid) state for
  # re-extraction. NO cleanup — a reject withheld the COMMIT (ledger delta at the gate, processed
  # flag at completion); any spent-markers already applied are verdict-free graph facts, correct
  # and idempotent under re-extraction once the code is fixed.
  def terminate({:decode_failed, _}, _st), do: :ok
  def terminate({:tx_crashed, _}, _st), do: :ok
  def terminate({:validation_rejected, _}, _st), do: :ok

  # ROLLBACK / supervisor shutdown (:shutdown, :kill, etc.): the block is orphaned. STOP the
  # retriers, CONFIRM dead, THEN clean this block's UTXOs — in that exact order.
  def terminate(_reason, %{pending: pending, hash: hash, slot: slot}) do
    # 1. Fire kills at every still-live retrier.
    Enum.each(pending, fn {pid, _ref} -> Process.exit(pid, :kill) end)
    # 2. CONFIRM each is dead (bounded, so a stuck kill can't wedge rollback).
    await_all_down(pending)
    # 3. Only now clean THIS block's DB effects. All writes (retriers' + this cleanup) go through
    #    the single-connection Ecto pool, which serialises this AFTER any write a now-dead retrier
    #    already enqueued. Children confirmed dead (step 2) ⇒ no NEW writes can enter after this.
    ChainStore.rollback_block(hash, slot)
    :ok
  end

  defp await_all_down(pending) when map_size(pending) == 0, do: :ok

  defp await_all_down(pending) do
    receive do
      {:DOWN, _ref, :process, pid, _reason} -> await_all_down(Map.delete(pending, pid))
    after
      @down_wait_ms -> :ok
    end
  end

  defp short(hash), do: hash |> Base.encode16(case: :lower) |> binary_part(0, 8)
end
