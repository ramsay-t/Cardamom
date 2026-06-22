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

  # The 1962 mux invariant: a mini-protocol message (a ~1KB block) may be split
  # across SDU boundaries. The codec MUST distinguish "valid CBOR prefix, just
  # truncated — wait for more bytes" (:incomplete) from "genuinely malformed"
  # ({:error, _}). Without this distinction the client can't carry the partial tail
  # forward, treats the split as a frame error, and loses sync for the rest of the
  # stream (the live block-fetch bug: 12 of ~55 blocks stored, 2026-06-22).
  describe "incomplete (truncated) messages — carry-over support" do
    # A real-shaped block: [4, #6.24(bytes)] with a ~1KB byte string, the only
    # block-fetch message large enough to span an SDU.
    defp big_block do
      wrapped = %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(1000)}}
      Codec.encode({:block, wrapped})
    end

    test "a block truncated mid-byte-string is :incomplete, NOT an error" do
      full = big_block()
      # Cut it well inside the byte string (head present, payload short).
      partial = binary_part(full, 0, div(byte_size(full), 2))
      assert :incomplete = Codec.decode(partial)
    end

    test "a block truncated at many lengths is consistently :incomplete" do
      full = big_block()

      for n <- [3, 5, 10, 50, 200, 500, byte_size(full) - 1] do
        assert :incomplete = Codec.decode(binary_part(full, 0, n)),
               "truncation at #{n} bytes must be :incomplete (a valid prefix), not an error"
      end
    end

    test "the exact-length buffer decodes (boundary: not incomplete)" do
      full = big_block()
      assert {:ok, {:block, _}, ""} = Codec.decode(full)
    end

    test "a complete message + a truncated next message: first decodes, rest is the partial tail" do
      # This is the live case: an SDU ends with a whole BatchDone-or-block followed
      # by the START of the next block. drain must consume the whole one and hand
      # back the partial tail to carry forward.
      whole = Codec.encode(:start_batch)
      partial = binary_part(big_block(), 0, 40)
      assert {:ok, :start_batch, rest} = Codec.decode(whole <> partial)
      assert rest == partial
      # And the partial tail on its own is :incomplete (wait for the next SDU).
      assert :incomplete = Codec.decode(rest)
    end

    test "genuinely malformed bytes are still {:error, _}, NOT :incomplete" do
      # A lone CBOR break / nonsense is corruption, not a short read — must stay an
      # error so a real protocol violation isn't mistaken for "wait for more".
      assert {:error, _} = Codec.decode(<<0xFF>>)
    end
  end
end
