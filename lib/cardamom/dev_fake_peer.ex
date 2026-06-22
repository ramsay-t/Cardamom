defmodule Cardamom.DevFakePeer do
  @moduledoc """
  DEV-ONLY byte-level fake relay. Speaks REAL chain-sync wire bytes (CBOR +
  SDU framing) into a `Cardamom.Channel`, so the entire receive-and-parse
  pipeline (`Cardamom.Connection`) runs for real against locally-generated
  traffic. The ONLY thing not exercised is the actual TCP socket.

  This replaces the old `DevHeartbeat` (which faked telemetry at the top of the
  stack). Now the fake is at the BOTTOM — it emits wire bytes; the real parser
  produces the telemetry. Swapping this for a real relay = swap the channel for
  `Channel.Tcp`.

  It plays the chain-sync RESPONDER (server agency): waits for our RequestNext,
  then replies with a header — mostly RollForward (monotonic slots), occasional
  RollBackward — so it looks like a real chain, not random noise.

  DELETE (or gate to :dev only) once we connect to a real relay.
  """

  use GenServer

  alias Cardamom.{Channel, Mux.Frame, Mux.SDU}
  alias Cardamom.Protocol.ChainSync.Codec, as: ChainSync

  @chain_sync 2

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)
    {:ok, %{channel: channel, buffer: <<>>, slot: 1_000_000, last_hash: nil}, {:continue, :loop}}
  end

  @impl true
  def handle_continue(:loop, state), do: recv_once(state)

  @impl true
  def handle_info(:recv, state), do: recv_once(state)

  # Wait for the client's RequestNext, then answer with a chain-sync reply.
  defp recv_once(state) do
    case Channel.recv(state.channel, 30_000) do
      {:ok, bytes} ->
        state = drain(%{state | buffer: state.buffer <> bytes})
        send(self(), :recv)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :recv)
        {:noreply, state}

      {:error, _} ->
        {:stop, :normal, state}
    end
  end

  defp drain(state) do
    case SDU.decode(state.buffer) do
      {:ok, %{protocol_num: @chain_sync, payload: payload}, rest} ->
        state = react(payload, %{state | buffer: rest})
        drain(state)

      {:ok, _other, rest} ->
        drain(%{state | buffer: rest})

      {:error, _incomplete} ->
        state
    end
  end

  defp react(payload, state) do
    case ChainSync.decode(payload) do
      {:ok, :request_next, _} ->
        # Pace it so the stream is watchable in the UI (a real relay is paced by
        # block production anyway — ~20s between blocks at the tip).
        Process.sleep(400)
        reply_next(state)

      {:ok, {:find_intersect, _}, _} ->
        reply_intersect(state)

      _ ->
        state
    end
  end

  # ~1 in 12 replies is a rollback (rare, like a real chain); else roll forward.
  # Roll-forwards emit STRUCTURALLY-REAL Conway headers (real bytes ~825,
  # real blake2b-256, [era, wrapCBORinCBOR] envelope), chained to the previous
  # header's hash — so the dev loopback exercises the real decode/forest path.
  defp reply_next(state) do
    if :rand.uniform(12) == 1 and state.slot > 1_000_010 do
      back_to = state.slot - :rand.uniform(5)
      send_msg(state, {:roll_backward, point(back_to), tip(state.slot, state.last_hash)})
      %{state | slot: back_to}
    else
      slot = state.slot + 1
      hdr = build_header(slot, state.last_hash)
      send_msg(state, {:roll_forward, hdr.envelope, tip(slot, hdr.hash)})
      %{state | slot: slot, last_hash: hdr.hash}
    end
  end

  defp reply_intersect(state) do
    send_msg(state, {:intersect_found, point(state.slot), tip(state.slot, state.last_hash)})
    state
  end

  defp send_msg(state, msg) do
    Frame.send_msg(state.channel, @chain_sync, ChainSync.encode(msg))
  end

  defp build_header(slot, prev_hash),
    do: Cardamom.Ledger.Conway.HeaderBuilder.build(block_number: slot, slot: slot, prev_hash: prev_hash)

  # point = [slot, hash]; tip = [point, block_no]. Use the real header hash where
  # we have it, else a random 32-byte stand-in (only for the bootstrap point).
  defp point(slot), do: [slot, %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(32)}]
  defp tip(slot, nil), do: [point(slot), slot]
  defp tip(slot, hash), do: [[slot, %CBOR.Tag{tag: :bytes, value: hash}], slot]
end
