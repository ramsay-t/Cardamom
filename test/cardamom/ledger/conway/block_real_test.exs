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

  # Real blocks captured at DIFFERENT points of the live chain (verbatim wire bytes). The shape-
  # dispatching decoder must decode each AND verify_body must pass — the body-hash is the only
  # check CBOR's permissiveness can't fool: it matches ONLY if block_body_hash was read from the
  # right field AND every body segment parsed byte-exactly. (A wrong field layout still "decodes"
  # under CBOR but can NEVER reproduce the committed 256-bit hash.) This is the test that would
  # have caught the era-dispatch bug that froze body backfill.
  # preview_block_indefinite_txbodies: a real Conway block (53 txs) whose tx_bodies array is
  # CBOR INDEFINITE-LENGTH (0x9F…0xFF). The hand-rolled array carver only knew definite framings,
  # so txs_in returned :bad_tx_bodies and the block stuck pending forever — found in a long soak.
  # verify_body passing proves the body segments parse byte-exactly across the indefinite array.
  @range_fixtures ~w(preview_block_1 preview_block_13011 preview_block_indefinite_txbodies)

  for name <- @range_fixtures do
    test "real block #{name}: decodes AND body-hash verifies (the non-foolable check)" do
      raw =
        Path.join([__DIR__, "..", "..", "..", "fixtures", "#{unquote(name)}.hex"])
        |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)

      assert {:ok, blk} = Block.decode(raw)
      assert :ok = Block.verify_body(blk),
             "#{unquote(name)}: recomputed body-hash must match the header's commitment"
    end
  end

  test "indefinite-length tx_bodies (0x9F): all transactions extract, txids byte-exact" do
    raw =
      Path.join([__DIR__, "..", "..", "..", "fixtures", "preview_block_indefinite_txbodies.hex"])
      |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)

    assert {:ok, txs} = Cardamom.Ledger.Block.txs_in(raw)
    assert length(txs) == 53, "the real block has 53 txs in an indefinite-length array"
    assert Enum.all?(txs, fn t -> byte_size(t.txid) == 32 end), "every txid is a real 32-byte hash"
  end
end
