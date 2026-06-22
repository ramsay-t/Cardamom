defmodule Cardamom.Mux.SDUTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias Cardamom.Mux.SDU

  # Byte-level spec: docs/wire-protocol.md "SDU header — byte-level spec",
  # read from network-mux/src/Network/Mux/Codec.hs.
  #
  # 8-byte big-endian header, then payload:
  #   bytes 0-3 : transmission time      (u32 BE, microsecond ticks)
  #   bytes 4-5 : (dir_bit << 15) | (mini_protocol_num & 0x7fff)   (u16 BE)
  #   bytes 6-7 : length                 (u16 BE, payload byte count)
  #   payload   : exactly `length` bytes
  #
  # Direction bit (CODE is truth, the source comment is wrong — see finding):
  #   0 = initiator, 1 = responder. We dial out, so we send dir = :initiator.

  describe "encode/1 produces the documented byte layout" do
    test "header field packing, big-endian" do
      sdu = %SDU{
        timestamp: 0x0A0B0C0D,
        protocol_num: 2,
        direction: :initiator,
        payload: "hi"
      }

      assert SDU.encode(sdu) ==
               <<0x0A0B0C0D::32, 0::1, 2::15, 2::16, "hi"::binary>>
    end

    test "responder direction sets the top bit (0x8000)" do
      sdu = %SDU{timestamp: 0, protocol_num: 8, direction: :responder, payload: ""}
      <<_ts::32, dir_and_num::16, _len::16>> = SDU.encode(sdu)
      assert (dir_and_num &&& 0x8000) == 0x8000
      assert (dir_and_num &&& 0x7FFF) == 8
    end

    test "initiator direction clears the top bit" do
      sdu = %SDU{timestamp: 0, protocol_num: 2, direction: :initiator, payload: ""}
      <<_ts::32, dir_and_num::16, _len::16>> = SDU.encode(sdu)
      assert (dir_and_num &&& 0x8000) == 0
    end

    test "length field equals payload byte count" do
      sdu = %SDU{timestamp: 1, protocol_num: 2, direction: :initiator, payload: "abcde"}
      <<_ts::32, _dn::16, len::16, _rest::binary>> = SDU.encode(sdu)
      assert len == 5
    end
  end

  describe "decode/1" do
    test "decodes a well-formed frame into header fields + payload" do
      frame = <<0x0A0B0C0D::32, 0::1, 2::15, 2::16, "hi"::binary>>
      assert {:ok, sdu, ""} = SDU.decode(frame)
      assert sdu.timestamp == 0x0A0B0C0D
      assert sdu.protocol_num == 2
      assert sdu.direction == :initiator
      assert sdu.payload == "hi"
    end

    test "returns trailing bytes (streaming-friendly: header+payload, then rest)" do
      frame = <<0::32, 0::1, 2::15, 2::16, "hi"::binary>>
      assert {:ok, _sdu, <<0xFF, 0xFE>>} = SDU.decode(frame <> <<0xFF, 0xFE>>)
    end

    test "decodes responder direction" do
      frame = <<0::32, 1::1, 8::15, 0::16>>
      assert {:ok, %SDU{direction: :responder, protocol_num: 8}, ""} = SDU.decode(frame)
    end
  end

  describe "decode/1 STRICT — reject, never coerce (enforce-don't-coerce directive)" do
    test "rejects a frame whose payload is shorter than the declared length" do
      # header says 5 bytes of payload, only 2 present — must NOT coerce/trim
      frame = <<0::32, 0::1, 2::15, 5::16, "hi"::binary>>
      assert {:error, _} = SDU.decode(frame)
    end

    test "rejects a truncated header (< 8 bytes)" do
      assert {:error, _} = SDU.decode(<<0::32, 0::16>>)
    end

    test "rejects empty input" do
      assert {:error, _} = SDU.decode(<<>>)
    end
  end

  # MC/DC-style boundary: the `payload::binary-size(len)` match succeeds iff at
  # least `len` bytes follow. Exercise len-1 (reject), exactly len (accept, no
  # trailing), len+1 (accept, 1 trailing byte).
  describe "payload-length boundary (binary-size match)" do
    defp frame_with(declared_len, payload), do: <<0::32, 0::1, 2::15, declared_len::16, payload::binary>>

    test "exactly len bytes: decodes, empty rest" do
      assert {:ok, sdu, ""} = SDU.decode(frame_with(3, "abc"))
      assert sdu.payload == "abc"
    end

    test "len-1 bytes present: rejected (short payload, not coerced)" do
      assert {:error, _} = SDU.decode(frame_with(3, "ab"))
    end

    test "len+1 bytes present: decodes len, 1 byte of rest" do
      assert {:ok, sdu, <<0x21>>} = SDU.decode(frame_with(3, "abc!"))
      assert sdu.payload == "abc"
    end

    test "zero-length payload decodes to empty (boundary at 0)" do
      assert {:ok, %SDU{payload: ""}, ""} = SDU.decode(frame_with(0, ""))
    end
  end

  describe "properties" do
    property "encode then decode is the identity (round-trip)" do
      check all ts <- integer(0..0xFFFFFFFF),
                num <- integer(0..0x7FFF),
                dir <- member_of([:initiator, :responder]),
                payload <- binary(max_length: 64),
                payload != "" do
        sdu = %SDU{timestamp: ts, protocol_num: num, direction: dir, payload: payload}
        assert {:ok, decoded, ""} = SDU.decode(SDU.encode(sdu))
        assert decoded == sdu
      end
    end

    property "decode never raises on arbitrary bytes — only {:ok, _, _} or {:error, _}" do
      check all bytes <- binary(max_length: 64) do
        case SDU.decode(bytes) do
          {:ok, %SDU{}, rest} when is_binary(rest) -> :ok
          {:error, _} -> :ok
        end
      end
    end
  end
end
