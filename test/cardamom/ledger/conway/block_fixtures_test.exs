defmodule Cardamom.Ledger.Conway.BlockFixturesTest do
  @moduledoc """
  GROUND-TRUTH replay over REAL Preview blocks dumped to flat hex fixtures
  (test/fixtures/blocks/block-N.hex, via scripts/dump_block_fixtures.sh from the
  production store). Reads the fixtures DIRECTLY — no ChainStore, no DB — so it works
  on the empty test DB and proves decode + body-hash verify against real bytes a
  Cardano node produced. This is the anti-circular guard at scale: many real blocks,
  not just one, not built by our own BlockBuilder.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Conway.Block

  @dir Path.join([__DIR__, "..", "..", "..", "fixtures", "blocks"])

  defp fixtures do
    case File.ls(@dir) do
      {:ok, files} -> files |> Enum.filter(&String.ends_with?(&1, ".hex")) |> Enum.sort()
      _ -> []
    end
  end

  test "real block fixtures exist (dumped from the store)" do
    assert fixtures() != [], "run scripts/dump_block_fixtures.sh to create fixtures"
  end

  test "every real block fixture decodes AND its body verifies against the header" do
    for file <- fixtures() do
      raw = @dir |> Path.join(file) |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)

      assert {:ok, blk} = Block.decode(raw), "#{file} must decode"
      assert :ok = Block.verify_body(blk), "#{file} body must verify (our hashAlonzoSegWits matches Cardano)"
      assert byte_size(blk.raw) == byte_size(raw), "#{file} kept verbatim"
    end
  end

  test "fixtures form a linked chain (each prev_hash = the previous block's hash)" do
    blocks =
      fixtures()
      |> Enum.map(fn file ->
        raw = @dir |> Path.join(file) |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
        {:ok, blk} = Block.decode(raw)
        blk
      end)
      |> Enum.sort_by(& &1.header.block_number)

    blocks
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] ->
      assert b.header.prev_hash == a.hash,
             "block #{b.header.block_number} prev_hash must link to block #{a.header.block_number}"
    end)
  end
end
