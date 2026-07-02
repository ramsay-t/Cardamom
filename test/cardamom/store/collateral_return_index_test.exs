defmodule Cardamom.Store.CollateralReturnIndexTest do
  @moduledoc """
  REGRESSION (real-block, non-foolable): an INVALID (phase-2-failed) transaction's
  collateral-return output is created at TxIx = length(outputs) — the count of the tx's DECLARED
  normal outputs — NOT at index 0. SPEC: Babbage/Collateral.hs collOuts →
  `txIxFromIntegral (length (outputs))`. We had hardcoded index 0, so a later tx spending the
  collateral-return at its real index found nothing and its block stuck pending forever (found on
  live Preview: block 52578's invalid tx 842a18e8, whose #1 = the 7₳ collateral return that block
  52579 spends — confirmed via Cardanoscan).

  Fixture: the REAL Preview block 52578 (era 6), which contains that invalid tx at body index 0.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{ChainStore, Ledger.Block}
  alias Cardamom.Store.{Repo, Txo}

  @fixture Path.join([__DIR__, "..", "..", "fixtures", "preview_block_invalid_tx.hex"])

  # Extraction is async (BlockHandler + per-tx retriers); wait for `check` or the deadline.
  defp eventually(check, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(check, deadline)
  end

  defp do_eventually(check, deadline) do
    cond do
      check.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> Process.sleep(20); do_eventually(check, deadline)
    end
  end

  test "invalid tx's collateral return lands at index length(outputs), not 0" do
    raw = @fixture |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)

    {:ok, txs} = Block.txs_in(raw)
    invalid = Enum.find(txs, &(&1.valid == false))
    assert invalid, "block 52578 has an invalid (phase-2-failed) tx"
    assert invalid.collateral_return, "the invalid tx has a collateral_return output"
    n = length(invalid.outputs)
    assert n == 1, "the real tx declares 1 normal output (so coll-return index must be 1)"

    # Extract async: this block's invalid tx spends collateral from a producer NOT in this test's
    # store, so its retrier retries forever (the block never fully completes here — correct new
    # behaviour). We only care that PHASE 1 created the collateral-return OUTPUT, so wait for that
    # output to appear rather than for the whole block to finish.
    :ok = ChainStore.extract_block(:crypto.strong_rand_bytes(32), raw, 52578)

    :ok = eventually(fn -> Repo.get_by(Txo, txid: invalid.txid, ix: n) != nil end)

    # The collateral-return TXO must be at index n (= 1 here), the index the spender references.
    assert Repo.get_by(Txo, txid: invalid.txid, ix: n),
           "collateral return stored at index #{n} (length of declared outputs)"

    # And NOT at index 0 (the old buggy location) — unless n happens to be 0.
    if n > 0 do
      refute Repo.get_by(Txo, txid: invalid.txid, ix: 0),
             "collateral return must NOT be at index 0 for a tx with #{n} declared output(s)"
    end
  end
end
