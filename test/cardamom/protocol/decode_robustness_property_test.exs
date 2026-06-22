defmodule Cardamom.Protocol.DecodeRobustnessPropertyTest do
  @moduledoc """
  The decoders sit on the Harvard boundary: they consume UNTRUSTED network bytes, so
  they must NEVER crash on arbitrary or truncated input — only return {:error, _} (or
  {:ok, _}). A decoder that raises on malformed bytes is a remote DoS. These
  properties hammer each decoder with random bytes and with truncations of valid
  messages — the input space coverage % can't reach.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cardamom.Protocol.ChainSync.Codec, as: CS
  alias Cardamom.Protocol.BlockFetch.Codec, as: BF
  alias Cardamom.Ledger.Conway.Block
  alias Cardamom.Ledger.Conway.BlockBuilder

  defp ok_or_error(result) do
    case result do
      {:ok, _, _} -> true
      {:ok, _} -> true
      {:error, _} -> true
      _ -> false
    end
  end

  property "chain-sync codec never raises on arbitrary bytes" do
    check all bytes <- binary(max_length: 200) do
      assert ok_or_error(CS.decode(bytes))
    end
  end

  property "block-fetch codec never raises on arbitrary bytes" do
    check all bytes <- binary(max_length: 200) do
      assert ok_or_error(BF.decode(bytes))
    end
  end

  property "block decoder never raises on arbitrary bytes" do
    check all bytes <- binary(max_length: 300) do
      assert match?({:error, _}, Block.decode(bytes)) or match?({:ok, _}, Block.decode(bytes))
    end
  end

  property "block decoder never raises on TRUNCATIONS of a real-shaped block" do
    full = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 2).raw

    check all n <- integer(0..byte_size(full)) do
      truncated = binary_part(full, 0, n)
      # Any prefix of a valid block must decode-or-error, never crash.
      assert match?({:error, _}, Block.decode(truncated)) or match?({:ok, _}, Block.decode(truncated))
    end
  end

  property "block-fetch codec never raises on truncations of a real MsgBlock" do
    blk = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 1)
    msg = BF.encode({:block, blk.envelope})

    check all n <- integer(0..byte_size(msg)) do
      assert ok_or_error(BF.decode(binary_part(msg, 0, n)))
    end
  end
end
