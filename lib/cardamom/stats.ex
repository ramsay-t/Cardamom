defmodule Cardamom.Stats do
  @moduledoc """
  Read-only observability hub. Subscribes to `:telemetry` events emitted across
  the node and keeps a small in-memory snapshot for the UI to read.

  This is the read-only seam the UI talks to (see architecture.md "the UI is a
  READ-ONLY observer"): it never drives the node, it only records what flowed by.
  Everything — logs, future forensic store, the browser UI — hangs off the same
  telemetry event spine.
  """

  use GenServer

  @events [
    [:cardamom, :peer, :connected],
    [:cardamom, :peer, :disconnected],
    [:cardamom, :protocol, :event]
  ]

  # ---- API ----

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Current snapshot for the UI."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  # ---- Telemetry → GenServer ----

  @doc false
  def handle_event(name, measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:telemetry, name, measurements, metadata})
  end

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    :telemetry.attach_many(
      "cardamom-stats",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok,
     %{
       peers_connected: 0,
       protocol_events: 0,
       recent: []
     }}
  end

  # Uptime is a NODE property, not a Stats-process one: the VM's own wall_clock since boot.
  # Resets exactly when the BEAM (re)starts, survives a Stats-process restart, and is immune to
  # system-clock/NTP jumps — unlike `System.system_time - started_at`, which also risked reading
  # a stale start point. (The 6-day "uptime" that looked broken was actually a stale browser tab;
  # this makes the value robust AND the UI now polls + shows disconnected — belt and braces.)
  defp node_uptime_seconds do
    {total_ms, _since_last_call} = :erlang.statistics(:wall_clock)
    div(total_ms, 1000)
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap = %{
      uptime_seconds: node_uptime_seconds(),
      peers_connected: state.peers_connected,
      protocol_events: state.protocol_events,
      # newest-first: state.recent is already prepended newest-first, so we
      # serve it as-is and the page renders latest at the top.
      recent: state.recent
    }

    {:reply, snap, state}
  end

  @impl true
  def handle_cast({:telemetry, name, measurements, metadata}, state) do
    line = %{
      at: System.system_time(:millisecond),
      event: Enum.join(name, "."),
      measurements: measurements,
      metadata: metadata
    }

    state =
      state
      |> bump(name)
      |> Map.update!(:recent, fn recent -> Enum.take([line | recent], 50) end)

    {:noreply, state}
  end

  defp bump(state, [:cardamom, :peer, :connected]),
    do: Map.update!(state, :peers_connected, &(&1 + 1))

  defp bump(state, [:cardamom, :peer, :disconnected]),
    do: Map.update!(state, :peers_connected, &max(&1 - 1, 0))

  defp bump(state, [:cardamom, :protocol, :event]),
    do: Map.update!(state, :protocol_events, &(&1 + 1))

  defp bump(state, _other), do: state
end
