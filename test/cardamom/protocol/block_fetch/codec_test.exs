defmodule Cardamom.Protocol.BlockFetch.CodecTest do
  @moduledoc """
  Block-fetch codec: every message variant round-trips, points encode as CBOR BYTE
  strings (the chain-sync resume-bug lesson), and unknown/garbage is a clean error
  (never a raise — Harvard boundary). Covers the branches the live/property tests
  don't exercise directly.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Protocol.BlockFetch.Codec

  describe "client-sent messages" do
    test "request_range round-trips; point hashes become CBOR byte strings" do
      msg = {:request_range, [10, <<0xAA, 0xBB>>], [20, <<0xCC, 0xDD>>]}

      assert {:ok, {:request_range, [10, from_h], [20, to_h]}, ""} = Codec.decode(Codec.encode(msg))
      assert %CBOR.Tag{tag: :bytes, value: <<0xAA, 0xBB>>} = from_h
      assert %CBOR.Tag{tag: :bytes, value: <<0xCC, 0xDD>>} = to_h
    end

    test "request_range with origin points ([]) passes through" do
      msg = {:request_range, [], []}
      assert {:ok, {:request_range, [], []}, ""} = Codec.decode(Codec.encode(msg))
    end

    test "client_done round-trips" do
      assert {:ok, :client_done, ""} = Codec.decode(Codec.encode(:client_done))
    end
  end

  describe "server-sent messages" do
    test "start_batch / no_blocks / batch_done round-trip" do
      assert {:ok, :start_batch, ""} = Codec.decode(Codec.encode(:start_batch))
      assert {:ok, :no_blocks, ""} = Codec.decode(Codec.encode(:no_blocks))
      assert {:ok, :batch_done, ""} = Codec.decode(Codec.encode(:batch_done))
    end

    test "block round-trips (opaque wrapped payload preserved)" do
      wrapped = %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: <<1, 2, 3>>}}
      assert {:ok, {:block, decoded}, ""} = Codec.decode(Codec.encode({:block, wrapped}))
      assert %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: <<1, 2, 3>>}} = decoded
    end
  end

  describe "strictness" do
    test "an unknown message tag is a clean error, not a raise" do
      assert {:error, {:unknown_block_fetch_message, _}} = Codec.decode(CBOR.encode([99]))
    end

    test "non-array / garbage CBOR is a clean error" do
      assert {:error, {:unknown_block_fetch_message, _}} = Codec.decode(CBOR.encode(%{not: "an array"}))
    end

    test "undecodable bytes return a cbor error (no raise)" do
      assert {:error, _} = Codec.decode(<<0xFF, 0xFF, 0xFF>>)
    end

    test "trailing bytes after a message are returned as rest (multi-message SDU support)" do
      # StartBatch followed by BatchDone in one buffer — the drain case.
      buf = Codec.encode(:start_batch) <> Codec.encode(:batch_done)
      assert {:ok, :start_batch, rest} = Codec.decode(buf)
      assert {:ok, :batch_done, ""} = Codec.decode(rest)
    end
  end
end
