defmodule Cardamom.Protocol.ChainSync.CodecTest do
  use ExUnit.Case, async: true

  alias Cardamom.Protocol.ChainSync.Codec

  # Grammar: chain-sync.cddl (ouroboros-network). Each message = CBOR array with
  # a leading integer tag:
  #   msgRequestNext       = [0]
  #   msgAwaitReply        = [1]
  #   msgRollForward       = [2, header, tip]
  #   msgRollBackward      = [3, point, tip]
  #   msgFindIntersect     = [4, points]
  #   msgIntersectFound    = [5, point, tip]
  #   msgIntersectNotFound = [6, tip]
  #   msgDone              = [7]
  #
  # For M1 (observe + log) we keep header/point/tip as OPAQUE terms — we do not
  # decode header internals yet. We model them as raw decoded-CBOR terms.

  # Opaque payloads are CBOR-native shapes (a point/tip on the wire is
  # [slot, hash-bytes]); we keep them opaque and only require round-trip stability.
  # NB: CBOR has no atom type, so payloads use ints/lists/binaries, not atom-keyed
  # maps — that's correct wire behaviour, not a codec bug.
  @point [50, <<0xBB, 0xBB>>]
  @tip [100, <<0xCC, 0xCC>>]
  @header <<0xDE, 0xAD, 0xBE, 0xEF>>

  describe "client-sent messages" do
    test "request_next round-trips" do
      assert {:ok, :request_next, ""} = Codec.decode(Codec.encode(:request_next))
    end

    test "find_intersect encodes the point hash as a CBOR BYTE string (not text)" do
      # A raw binary hash would CBOR-encode as a TEXT string, which the real relay
      # rejects (it closed our connection on resume). encode/1 must wrap it as bytes,
      # so it round-trips as [slot, %CBOR.Tag{tag: :bytes}].
      msg = {:find_intersect, [[50, <<0xBB, 0xBB>>]]}

      assert {:ok, {:find_intersect, [[50, point_hash]]}, ""} = Codec.decode(Codec.encode(msg))
      assert %CBOR.Tag{tag: :bytes, value: <<0xBB, 0xBB>>} = point_hash
    end

    test "done round-trips" do
      assert {:ok, :done, ""} = Codec.decode(Codec.encode(:done))
    end
  end

  describe "server-sent messages" do
    test "await_reply round-trips" do
      assert {:ok, :await_reply, ""} = Codec.decode(Codec.encode(:await_reply))
    end

    test "roll_forward carries an (opaque) header and tip" do
      msg = {:roll_forward, @header, @tip}
      assert {:ok, ^msg, ""} = Codec.decode(Codec.encode(msg))
    end

    test "roll_backward carries a point and tip" do
      msg = {:roll_backward, @point, @tip}
      assert {:ok, ^msg, ""} = Codec.decode(Codec.encode(msg))
    end

    test "intersect_found / intersect_not_found round-trip" do
      f = {:intersect_found, @point, @tip}
      nf = {:intersect_not_found, @tip}
      assert {:ok, ^f, ""} = Codec.decode(Codec.encode(f))
      assert {:ok, ^nf, ""} = Codec.decode(Codec.encode(nf))
    end
  end

  # MC/DC-style: from_term/1 catch-all non-matched in each distinct way, and the
  # `[4, points] when is_list(points)` guard falsified independently.
  describe "message pattern non-matched in each distinct way" do
    test "find_intersect with non-list points -> falls through to unknown" do
      assert {:error, {:unknown_message, _}} = Codec.decode(CBOR.encode([4, 42]))
    end

    test "known tag, wrong arity (roll_forward missing tip) -> unknown" do
      assert {:error, {:unknown_message, _}} = Codec.decode(CBOR.encode([2, <<0>>]))
    end

    test "known tag, extra element (request_next with payload) -> unknown" do
      assert {:error, {:unknown_message, _}} = Codec.decode(CBOR.encode([0, 99]))
    end

    test "empty array -> unknown" do
      assert {:error, {:unknown_message, _}} = Codec.decode(CBOR.encode([]))
    end

    test "not an array (bare int) -> unknown" do
      assert {:error, {:unknown_message, _}} = Codec.decode(CBOR.encode(2))
    end

    test "every defined tag 0..7 decodes (no gap in the tag space)" do
      assert {:ok, :request_next, ""} = Codec.decode(CBOR.encode([0]))
      assert {:ok, :await_reply, ""} = Codec.decode(CBOR.encode([1]))
      assert {:ok, :done, ""} = Codec.decode(CBOR.encode([7]))
      # tag 8 is one past the defined space -> unknown
      assert {:error, {:unknown_message, _}} = Codec.decode(CBOR.encode([8]))
    end
  end

  describe "decode STRICT" do
    test "rejects an unknown tag" do
      assert {:error, _} = Codec.decode(CBOR.encode([99]))
    end

    test "never raises on arbitrary bytes" do
      for _ <- 1..200 do
        bytes = :crypto.strong_rand_bytes(:rand.uniform(16))
        assert match?({:ok, _, _}, Codec.decode(bytes)) or match?({:error, _}, Codec.decode(bytes))
      end
    end
  end
end
