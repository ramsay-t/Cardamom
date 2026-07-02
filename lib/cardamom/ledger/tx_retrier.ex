defmodule Cardamom.Ledger.TxRetrier do
  @moduledoc """
  The per-TRANSACTION retrier process: run ONE tx to GENUINE completion. Create its outputs once
  (phase 1, idempotent), then apply its spends — and if a spend's producer TXO isn't in the store
  yet, RETRY CONTINUOUSLY (no timeout) until it appears. The retry IS the ordering: a tx spending
  an intra-container sibling's output, or a cross-container output backfilled later, simply waits.
  "It's not done until it's done." The BEAM way — retry and the distributed system sorts itself out.

  One of these runs per tx, spawned + monitored by the block's `Cardamom.Ledger.BlockHandler`. It
  reports `{:tx_done, self()}` to its parent only when EVERY spend has applied, then returns
  (exits :normal). It has NO stop condition of its own — the ONLY thing that stops a retrier is its
  parent handler being terminated (rollback/graveyard of the owning block), which kills it. See
  [[Cardamom.Ledger.TxHandler]] for the per-phase UTxO logic.
  """

  alias Cardamom.Ledger.TxHandler

  # Retry interval for an unresolved spend. The retry IS the ordering, so this only trades latency
  # vs. CPU — never correctness (there is no deadline). Short: sibling/backfill outputs land fast.
  @retry_ms 50

  @doc "Run `tx` (a decoded tx map) to completion, reporting to `parent`. `slot` stamped for rollback."
  def run(parent, tx, slot) do
    :ok = TxHandler.create_outputs(tx, slot)
    apply_until_done(parent, tx, slot)
  end

  defp apply_until_done(parent, tx, slot) do
    case TxHandler.apply_spends(tx, slot) do
      {:ok, []} ->
        # Genuinely done — every spend applied. Report and return (exit :normal).
        send(parent, {:tx_done, self()})

      {:ok, _unresolved} ->
        # A spend's producer isn't stored yet. NOT an error — wait and retry (the retry is the
        # ordering). No deadline: a rollback of the owning block is what stops us, via a kill.
        Process.sleep(@retry_ms)
        apply_until_done(parent, tx, slot)
    end
  end
end
