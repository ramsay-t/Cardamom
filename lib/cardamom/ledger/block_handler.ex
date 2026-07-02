defmodule Cardamom.Ledger.BlockHandler do
  @moduledoc """
  The CONTAINER handler for one block (and, identically, a Leios Endorser Block — just bigger). A
  GenServer that traps exits, registered by block hash in `Cardamom.Ledger.BlockRegistry`, owning
  one `Cardamom.Ledger.TxRetrier` process per tx.

  DONE = every tx retrier reported done. Only THEN do we `mark_txo_processed` and stop :normal.
  A retrier crash (non-:normal :DOWN) stops us non-normally, leaving txo_processed=false for the
  reconciler crash-backstop to re-spawn us later. A retrier retries CONTINUOUSLY (no timeout), so a
  handler for a block with a not-yet-ingested producer stays alive, retrying, until the producer
  arrives — or until a rollback terminates us.

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

  alias Cardamom.Ledger.{BlockRegistry, TxRetrier}
  alias Cardamom.ChainStore

  # Bound on await_all_down so a wedged kill can't hang rollback (child shutdown budget is 10s).
  @down_wait_ms 5_000

  def start_link({hash, _raw, _slot} = arg) when is_binary(hash) do
    GenServer.start_link(__MODULE__, arg, name: {:via, Registry, {BlockRegistry, hash}})
  end

  @impl true
  def init({hash, raw, slot}) do
    Process.flag(:trap_exit, true)
    {:ok, %{hash: hash, raw: raw, slot: slot, pending: %{}}, {:continue, :spawn_children}}
  end

  @impl true
  def handle_continue(:spawn_children, %{hash: hash, raw: raw, slot: slot} = st) do
    case Cardamom.Ledger.Block.txs_in(raw) do
      {:ok, []} ->
        # Empty block: trivially all-done.
        ChainStore.mark_txo_processed(hash)
        {:stop, :normal, st}

      {:ok, txs} ->
        me = self()

        pending =
          Map.new(txs, fn tx ->
            {pid, ref} = spawn_monitor(fn -> TxRetrier.run(me, tx, slot) end)
            {pid, ref}
          end)

        # MEMPOOL CASCADE: a confirmed block evicts pending mempool txs it out-competes. Idempotent
        # + monotone (evictions only push toward terminal states), order-independent — safe to run
        # at spawn time regardless of whether every UTxO chain has resolved yet.
        Enum.each(txs, &ChainStore.cascade_mempool/1)

        {:noreply, %{st | pending: pending}}

      {:error, reason} ->
        # Undecodable body — leave txo_processed=false; don't loop. Stop non-normal (no cleanup).
        {:stop, {:decode_failed, reason}, st}
    end
  end

  @impl true
  def handle_info({:tx_done, pid}, %{pending: pending} = st) do
    {ref, rest} = Map.pop(pending, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    st = %{st | pending: rest}

    if map_size(rest) == 0 do
      # EVERY tx completed → the block is genuinely, fully done.
      ChainStore.mark_txo_processed(st.hash)
      {:stop, :normal, st}
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

  # ---- terminate: the ordered kill-confirm-then-clean ----

  # Fully done: children already gone, DB is correct — nothing to clean.
  @impl true
  def terminate(:normal, _st), do: :ok

  # Decode failure / retrier crash: leave the partial (valid) state for re-extraction. NO cleanup.
  def terminate({:decode_failed, _}, _st), do: :ok
  def terminate({:tx_crashed, _}, _st), do: :ok

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
