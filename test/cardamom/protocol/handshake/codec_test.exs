defmodule Cardamom.Protocol.Handshake.CodecTest do
  use ExUnit.Case, async: true

  alias Cardamom.Protocol.Handshake.Codec

  # Grammar: handshake-node-to-node-v14.cddl
  #   msgProposeVersions = [0, versionTable]   (versionTable = definite map)
  #   msgAcceptVersion   = [1, versionNumber, nodeToNodeVersionData]
  #   msgRefuse          = [2, refuseReason]
  #   msgQueryReply      = [3, versionTable]
  # v14 nodeToNodeVersionData = [networkMagic, initiatorOnlyDiffusionMode, peerSharing, query]

  describe "propose_versions" do
    test "encodes [0, {version => versionData}] with definite-length map" do
      vd = %{network_magic: 2, initiator_only: true, peer_sharing: 0, query: false}
      bytes = Codec.encode({:propose_versions, %{14 => vd}})

      # 0x82 array(2), 0x00, 0xA1 = DEFINITE map(1) (not 0xBF indefinite)
      assert <<0x82, 0x00, 0xA1, _rest::binary>> = bytes
    end

    test "round-trips through decode" do
      vd = %{network_magic: 2, initiator_only: true, peer_sharing: 0, query: false}
      msg = {:propose_versions, %{14 => vd}}
      assert {:ok, ^msg, ""} = Codec.decode(Codec.encode(msg))
    end
  end

  describe "accept_version" do
    test "round-trips [1, version, versionData]" do
      vd = %{network_magic: 2, initiator_only: false, peer_sharing: 0, query: false}
      msg = {:accept_version, 14, vd}
      assert {:ok, ^msg, ""} = Codec.decode(Codec.encode(msg))
    end

    test "decodes a hand-built accept frame from the wire" do
      # [1, 14, [2, false, 0, false]]
      wire = CBOR.encode([1, 14, [2, false, 0, false]])
      assert {:ok, {:accept_version, 14, vd}, ""} = Codec.decode(wire)
      assert vd.network_magic == 2
      assert vd.initiator_only == false
    end
  end

  describe "refuse" do
    test "round-trips a version-mismatch refusal [2, [0, [versions]]]" do
      msg = {:refuse, {:version_mismatch, [14, 15, 16]}}
      assert {:ok, ^msg, ""} = Codec.decode(Codec.encode(msg))
    end

    test "round-trips a refused refusal [2, [2, version, reason]]" do
      msg = {:refuse, {:refused, 14, "go away"}}
      assert {:ok, ^msg, ""} = Codec.decode(Codec.encode(msg))
    end
  end

  # MC/DC-style: each guard condition in decode_vd/1 falsified INDEPENDENTLY
  # (others held valid), plus each distinct way the pattern is non-matched.
  # Guard: is_integer(m) and is_boolean(io) and ps in 0..1 and is_boolean(q).
  # A valid version_data is [magic, initiator_only, peer_sharing, query].
  describe "version_data guard — independent falsification of each condition" do
    defp vd_msg(version_data_list), do: CBOR.encode([1, 14, version_data_list])

    test "all-valid is accepted (the positive case)" do
      assert {:ok, {:accept_version, 14, _}, ""} = Codec.decode(vd_msg([2, true, 0, false]))
    end

    test "magic non-integer (others valid) -> reject" do
      assert {:error, _} = Codec.decode(vd_msg([<<"two">>, true, 0, false]))
    end

    test "initiator_only non-boolean (others valid) -> reject" do
      assert {:error, _} = Codec.decode(vd_msg([2, 7, 0, false]))
    end

    test "peer_sharing below range (=-1 not representable; use 2, others valid) -> reject" do
      assert {:error, _} = Codec.decode(vd_msg([2, true, 2, false]))
    end

    test "peer_sharing = 1 (upper bound, valid) -> accept" do
      assert {:ok, {:accept_version, 14, vd}, ""} = Codec.decode(vd_msg([2, true, 1, false]))
      assert vd.peer_sharing == 1
    end

    test "query non-boolean (others valid) -> reject" do
      assert {:error, _} = Codec.decode(vd_msg([2, true, 0, 9]))
    end

    test "version_data pattern non-matched: wrong arity (3 elements) -> reject" do
      assert {:error, _} = Codec.decode(vd_msg([2, true, 0]))
    end

    test "version_data pattern non-matched: wrong arity (5 elements) -> reject" do
      assert {:error, _} = Codec.decode(vd_msg([2, true, 0, false, 99]))
    end

    test "version_data pattern non-matched: not a list at all -> reject" do
      assert {:error, _} = Codec.decode(CBOR.encode([1, 14, 42]))
    end
  end

  # MC/DC for the refuse-reason clauses: each tag, plus each guard falsified.
  describe "refuse-reason clauses — each variant and each non-match" do
    test "handshake_decode_error (tag 1) round-trips (was previously untested)" do
      msg = {:refuse, {:handshake_decode_error, 14, "bad cbor"}}
      assert {:ok, ^msg, ""} = Codec.decode(Codec.encode(msg))
    end

    test "version_mismatch with non-list payload -> falls through to error" do
      assert {:error, {:bad_refuse_reason, _}} = Codec.decode(CBOR.encode([2, [0, 42]]))
    end

    test "refused with non-integer version -> falls through to error" do
      assert {:error, {:bad_refuse_reason, _}} = Codec.decode(CBOR.encode([2, [2, <<"v">>, "why"]]))
    end

    test "unknown refuse tag -> error" do
      assert {:error, {:bad_refuse_reason, _}} = Codec.decode(CBOR.encode([2, [9, "huh"]]))
    end
  end

  # from_term/1 catch-all: non-matched in each distinct way.
  describe "message pattern non-matched in each distinct way" do
    test "empty array -> unknown message" do
      assert {:error, {:unknown_message, _}} = Codec.decode(CBOR.encode([]))
    end

    test "not an array (bare integer) -> unknown message" do
      assert {:error, {:unknown_message, _}} = Codec.decode(CBOR.encode(7))
    end

    test "known tag, wrong arity (propose with no table) -> unknown message" do
      assert {:error, {:unknown_message, _}} = Codec.decode(CBOR.encode([0]))
    end

    test "propose_versions with a non-map version table -> error" do
      assert {:error, {:bad_version_table, _}} = Codec.decode(CBOR.encode([0, [1, 2, 3]]))
    end
  end

  describe "decode STRICT — reject, never coerce" do
    test "rejects an unknown message tag" do
      assert {:error, _} = Codec.decode(CBOR.encode([9, 14]))
    end

    test "rejects non-CBOR / garbage trailing structure" do
      assert {:error, _} = Codec.decode(<<0xFF, 0xFF, 0xFF>>)
    end

    test "never raises on arbitrary bytes" do
      for _ <- 1..200 do
        bytes = :crypto.strong_rand_bytes(:rand.uniform(20))

        assert match?({:ok, _, _}, Codec.decode(bytes)) or
                 match?({:error, _}, Codec.decode(bytes))
      end
    end
  end
end
