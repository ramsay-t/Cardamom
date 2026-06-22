defmodule Cardamom.Mux.Frame do
  @moduledoc """
  Send/receive a single mini-protocol message over a `Cardamom.Channel`, wrapped
  in one SDU. A thin convenience over `Cardamom.Mux.SDU` for protocols whose
  messages fit in one SDU (true for handshake/chain-sync control messages; large
  payloads needing multi-SDU splitting come later for block-fetch).

  `send_msg` frames `payload` for `protocol_num` and writes it. `recv_msg`
  reads one SDU and returns its payload (re-reading until a whole SDU is present,
  since a Channel may deliver partial bytes).
  """

  import Bitwise, only: [&&&: 2]
  alias Cardamom.{Channel, Mux.SDU}

  @doc "Frame `payload` as one SDU (initiator direction) and send it."
  @spec send_msg(Channel.t(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  def send_msg(channel, protocol_num, payload) do
    sdu = %SDU{
      timestamp: timestamp(),
      protocol_num: protocol_num,
      direction: :initiator,
      payload: payload
    }

    Channel.send(channel, SDU.encode(sdu))
  end

  @doc """
  Receive one complete SDU and return `{:ok, payload, sdu}` | `{:error, reason}`.
  Accumulates bytes across channel reads until a full SDU is decodable.
  """
  @spec recv_msg(Channel.t(), binary(), timeout()) ::
          {:ok, binary(), SDU.t(), binary()} | {:error, term()}
  def recv_msg(channel, buffer \\ <<>>, timeout \\ 5_000) do
    case SDU.decode(buffer) do
      {:ok, sdu, rest} ->
        {:ok, sdu.payload, sdu, rest}

      {:error, _incomplete} ->
        case Channel.recv(channel, timeout) do
          {:ok, more} -> recv_msg(channel, buffer <> more, timeout)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # 32-bit microsecond tick (wraps; see SDU spec).
  defp timestamp, do: System.monotonic_time(:microsecond) &&& 0xFFFFFFFF
end
