defmodule Cardamom.Ledger.Conway.BlockRealTest do
  @moduledoc """
  GROUND-TRUTH regression test: decode + verify a REAL Preview block captured from a
  live block-fetch (test/fixtures/preview_block_with_tx.hex). Unlike the BlockBuilder
  round-trip tests (which prove builder and decoder AGREE), this can only pass if our
  decode and our body-hash algorithm match what a real Cardano node actually produced
  — it caught two bugs the circular tests hid: the CDDL frame-fail and the missing
  era envelope (`[era, [header,...]]`).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Conway.Block

  @fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "preview_block_with_tx.hex"])

  setup do
    raw = @fixture |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
    %{raw: raw}
  end

  test "decodes a real era-wrapped Preview block", %{raw: raw} do
    assert {:ok, blk} = Block.decode(raw)
    # Real captured values (block index 3 of Preview's early chain).
    assert blk.header.block_number == 3
    assert blk.header.slot == 60
    assert blk.tx_count == 1, "this fixture has a real transaction"
    assert byte_size(blk.hash) == 32
    assert byte_size(blk.header.prev_hash) == 32, "links to its parent"
  end

  test "body verifies against the header's block_body_hash (algorithm matches Cardano)", %{raw: raw} do
    {:ok, blk} = Block.decode(raw)
    # THE ground-truth assertion: our hashAlonzoSegWits reimplementation reproduces
    # the body hash a real node committed to in the header.
    assert :ok = Block.verify_body(blk)
  end

  test "the block's raw bytes are kept verbatim (hash fidelity)", %{raw: raw} do
    {:ok, blk} = Block.decode(raw)
    assert blk.raw == raw
  end
end
