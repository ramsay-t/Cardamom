defmodule Cardamom.Protocol.DecodeRobustnessPropertyTest do
  @moduledoc """
  The decoders sit on the Harvard boundary: they consume UNTRUSTED network bytes, so
  they must NEVER crash on arbitrary or truncated input — only return {:error, _},
  {:ok, _}, or :incomplete (block-fetch: a valid-but-truncated prefix awaiting more
  bytes). A decoder that raises on malformed bytes is a remote DoS. These
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
      # block-fetch signals a valid-but-truncated prefix (carry-over across SDUs).
      :incomplete -> true
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

  # STRONGER: a truncation of a real MsgBlock is a valid PREFIX, so it must be
  # :incomplete (short read — carry over) or {:ok,...} (a full message, when n is the
  # whole length) — NEVER {:error, _}. An {:error, _} here is the live bug: the client
  # would treat the boundary split as corruption and lose stream sync. (n=0 is the
  # empty buffer → :incomplete.)
  property "a truncated real MsgBlock is :incomplete or :ok, never an error" do
    blk = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 1)
    msg = BF.encode({:block, blk.envelope})

    check all n <- integer(0..byte_size(msg)) do
      result = BF.decode(binary_part(msg, 0, n))

      assert result == :incomplete or match?({:ok, _, _}, result),
             "truncation at #{n}/#{byte_size(msg)} was #{inspect(result)} — a prefix must never be {:error, _}"
    end
  end
end
