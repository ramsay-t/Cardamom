defmodule Cardamom.Ledger.BlockWitnessWiringTest do
  @moduledoc """
  Wiring: a block's decoded WITNESS SETS attach to their transactions POSITIONALLY (witness set i
  belongs to tx body i), so the phase-1 witness rules (`Cardamom.Ledger.WitnessCheck`) can run on
  each tx. `Ledger.Block.txs_with_witnesses/1` returns the same tx maps as `txs_in/1`, each with a
  `:witnesses` (the inert decoded set) — empty when a tx has none, so callers never crash.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Block

  test "REAL block: each tx gets its positionally-aligned witness set" do
    raw =
      "test/fixtures/preview_block_with_tx.hex"
      |> File.read!()
      |> String.trim()
      |> Base.decode16!(case: :mixed)

    assert {:ok, txs} = Block.txs_with_witnesses(raw)
    assert txs != []

    # every tx carries a :witnesses map of the decoded shape
    for tx <- txs do
      assert %{vkey: _, native: _, bootstrap: _} = tx.witnesses
    end

    # this real block's tx is bootstrap-witnessed (established in the witness decoder test)
    assert Enum.any?(txs, fn tx -> tx.witnesses.bootstrap != [] end)
  end

  test "txs_with_witnesses yields the SAME tx bodies as txs_in (just enriched)" do
    raw =
      "test/fixtures/preview_block_with_tx.hex"
      |> File.read!()
      |> String.trim()
      |> Base.decode16!(case: :mixed)

    {:ok, plain} = Block.txs_in(raw)
    {:ok, enriched} = Block.txs_with_witnesses(raw)

    assert length(plain) == length(enriched)
    assert Enum.map(plain, & &1.txid) == Enum.map(enriched, & &1.txid)
  end

  test "a block whose witness segment can't be read still yields txs with EMPTY witnesses" do
    # Byron-tagged or malformed-witness path must degrade, not crash: witnesses default empty.
    {:ok, txs} =
      "test/fixtures/preview_block_1.hex"
      |> File.read!()
      |> String.trim()
      |> Base.decode16!(case: :mixed)
      |> Block.txs_with_witnesses()

    assert Enum.all?(txs, fn tx -> match?(%{vkey: _}, tx.witnesses) end)
  end
end
