defmodule Cardamom.LogReplayPeer do
  @moduledoc """
  Replays previously-LOGGED raw chain-sync bytes back to our Connection, with no
  network. Reads `chain_sync raw payload: <hex>` lines from a session log file
  and serves them one per `RequestNext`, consumer-driven exactly like a real
  relay (and like `SimPeer`) — wait for our request, then send the next logged
  payload. This turns a captured live run into a deterministic, repeatable,
  network-free benchmark/regression of the whole decode→forest pipeline against
  REAL data.

  It only serves the recorded server→client messages (RollForward/RollBackward
  etc.); it answers each `RequestNext` with the next recorded payload, and a
  `FindIntersect` with the first recorded payload's point if needed (we keep it
  simple: ignore intersect and just stream the recorded sequence).
  """

  use GenServer
  require Logger

  alias Cardamom.{Channel, Mux.SDU}
  alias Cardamom.Protocol.ChainSync.Codec, as: CS

  @chain_sync 2

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc "Extract the ordered list of raw chain-sync payloads (binaries) from a log file."
  @spec payloads_from_log(Path.t()) :: [binary()]
  def payloads_from_log(path) do
    path
    |> File.stream!()
    |> Stream.map(&Regex.run(~r/chain_sync raw payload: ([0-9a-f]+)/, &1, capture: :all_but_first))
    |> Stream.reject(&is_nil/1)
    |> Stream.map(fn [hex] -> Base.decode16!(hex, case: :lower) end)
    |> Enum.to_list()
  end

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)
    payloads = Keyword.get(opts, :payloads) || payloads_from_log(Keyword.fetch!(opts, :log))
    report_to = Keyword.get(opts, :report_to)
    {:ok, %{channel: channel, buffer: <<>>, queue: payloads, served: 0, report_to: report_to}, {:continue, :loop}}
  end

  @impl true
  def handle_continue(:loop, state), do: recv_once(state)

  @impl true
  def handle_info(:recv, state), do: recv_once(state)

  defp recv_once(state) do
    case Channel.recv(state.channel, 1000) do
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

  # Consumer-driven: on each RequestNext (and the opening FindIntersect), serve the
  # next recorded payload. When the recording is exhausted, report done and stop.
  defp react(payload, state) do
    case CS.decode(payload) do
      {:ok, :request_next, _} -> serve_next(state)
      {:ok, {:find_intersect, _}, _} -> serve_next(state)
      _ -> state
    end
  end

  defp serve_next(%{queue: []} = state) do
    if state.report_to, do: send(state.report_to, {:replay_done, state.served})
    state
  end

  defp serve_next(%{queue: [next | rest]} = state) do
    # `next` is the full raw chain-sync payload as recorded — frame it in an SDU
    # (responder direction) and send it, exactly as a relay would.
    sdu = %SDU{timestamp: 0, protocol_num: @chain_sync, direction: :responder, payload: next}
    Channel.send(state.channel, SDU.encode(sdu))
    %{state | queue: rest, served: state.served + 1}
  end
end
