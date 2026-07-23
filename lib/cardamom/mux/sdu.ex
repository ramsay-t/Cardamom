defmodule Cardamom.Mux.SDU do
  @moduledoc """
  Ouroboros mux Segment Data Unit (SDU): the 8-byte framing every mini-protocol
  message travels in over the single TCP bearer.

  Byte-level spec (read from `network-mux/src/Network/Mux/Codec.hs`, later confirmed
  against the prose spec `ouroboros-network/docs/network-spec/mux.tex`; written up in
  `docs/wire-protocol.md` and `docs/WIRE.md` §1). 8-byte big-endian header
  then payload:

      bytes 0-3 : transmission time   (u32 BE, microsecond ticks)
      bytes 4-5 : (dir_bit << 15) | (mini_protocol_num & 0x7fff)  (u16 BE)
      bytes 6-7 : length              (u16 BE, payload byte count)
      payload   : exactly `length` bytes

  Direction bit — the CODE is truth (the source comment is inverted, see the
  finding in docs/wire-protocol.md): `0 = initiator`, `1 = responder`. We dial
  out, so we send `:initiator`.

  Decoding is STRICT (enforce, never coerce — see the strict-CDDL directive): a
  frame whose payload is shorter than its declared length is an error, not a
  thing to trim or wait on at this layer.
  """

  import Bitwise

  @type direction :: :initiator | :responder

  @type t :: %__MODULE__{
          timestamp: 0..0xFFFFFFFF,
          protocol_num: 0..0x7FFF,
          direction: direction(),
          payload: binary()
        }

  @enforce_keys [:timestamp, :protocol_num, :direction, :payload]
  defstruct [:timestamp, :protocol_num, :direction, :payload]

  @dir_responder 0x8000
  @num_mask 0x7FFF

  @doc "Encode an SDU to its on-the-wire bytes."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{
        timestamp: ts,
        protocol_num: num,
        direction: dir,
        payload: payload
      })
      when ts in 0..0xFFFFFFFF and num in 0..0x7FFF and is_binary(payload) do
    dir_and_num = bor(dir_bit(dir), band(num, @num_mask))
    len = byte_size(payload)
    <<ts::32, dir_and_num::16, len::16, payload::binary>>
  end

  @doc """
  Decode one SDU off the front of a buffer.

  Returns `{:ok, sdu, rest}` where `rest` is any bytes after this SDU (the next
  frame, possibly partial) — streaming-friendly. Returns `{:error, reason}` for a
  truncated header or a payload shorter than the declared length. Never raises.
  """
  @spec decode(binary()) :: {:ok, t(), binary()} | {:error, term()}
  def decode(<<ts::32, dir_and_num::16, len::16, payload::binary-size(len), rest::binary>>) do
    sdu = %__MODULE__{
      timestamp: ts,
      protocol_num: band(dir_and_num, @num_mask),
      direction: direction_of(dir_and_num),
      payload: payload
    }

    {:ok, sdu, rest}
  end

  def decode(<<_ts::32, _dir_and_num::16, len::16, payload::binary>>)
      when byte_size(payload) < len do
    {:error, {:short_payload, declared: len, present: byte_size(payload)}}
  end

  def decode(buf) when is_binary(buf) do
    {:error, {:short_header, byte_size(buf)}}
  end

  defp dir_bit(:initiator), do: 0
  defp dir_bit(:responder), do: @dir_responder

  defp direction_of(dir_and_num) do
    if band(dir_and_num, @dir_responder) == 0, do: :initiator, else: :responder
  end
end
