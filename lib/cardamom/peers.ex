defmodule Cardamom.Peers do
  @moduledoc """
  Read-only registry of currently-open peer connections, for the UI's network
  topology view. Each `Cardamom.Connection` registers itself on start with the
  metadata the protocol actually provides — IP:port, negotiated version,
  direction — and per-protocol activity is derived from the existing
  `[:cardamom, :protocol, :event]` telemetry (no extra obligation on Connection).

  Peers are identified by IP:port; the protocol provides NO friendly name. The
  `name`/`pools` fields are an enrichment SLOT for later: cross-referencing the
  connected address against on-chain pool-registration relays (goal (b) ledger
  data). That mapping is many-to-many and best-effort (a relay can serve many
  pools; a pool registers many relays; some relays aren't on-chain), so it's
  never a clean 1:1 label — left empty until the ledger layer exists.

  Strictly read-only / observe-never-drive, like Stats and Introspect.
  """

  use GenServer

  @event [:cardamom, :protocol, :event]

  # ---- API ----

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Register a connection process with its connection metadata."
  def register(pid, meta), do: GenServer.call(__MODULE__, {:register, pid, meta})

  @doc "Current list of connected peers with metadata + per-protocol activity."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Clear all peers (test support)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc false
  def handle_event(@event, meas, meta, _config),
    do: GenServer.cast(__MODULE__, {:activity, meas, meta})

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    :telemetry.attach("cardamom-peers", @event, &__MODULE__.handle_event/4, nil)
    # %{pid => peer_map}, and an address->pid index for telemetry routing.
    {:ok, %{peers: %{}, by_address: %{}}}
  end

  @impl true
  def handle_call({:register, pid, meta}, _from, state) do
    Process.monitor(pid)

    peer = %{
      address: meta.address,
      direction: Map.get(meta, :direction, :outbound),
      version: Map.get(meta, :version),
      name: nil,
      pools: [],
      protocols: %{},
      connected_at: System.system_time(:second)
    }

    state =
      state
      |> put_in([:peers, pid], peer)
      |> put_in([:by_address, meta.address], pid)

    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state),
    do: {:reply, Map.values(state.peers), state}

  def handle_call(:reset, _from, _state),
    do: {:reply, :ok, %{peers: %{}, by_address: %{}}}

  @impl true
  def handle_cast({:activity, meas, meta}, state) do
    with addr when not is_nil(addr) <- Map.get(meta, :peer),
         pid when not is_nil(pid) <- state.by_address[addr],
         true <- Map.has_key?(state.peers, pid) do
      proto = to_string(Map.get(meta, :protocol, "unknown"))

      entry = %{
        count: get_in(state.peers, [pid, :protocols, proto, :count]) |> add(Map.get(meas, :count, 1)),
        last_msg: Map.get(meta, :msg),
        last_at: System.system_time(:millisecond)
      }

      {:noreply, put_in(state.peers[pid].protocols[proto], entry)}
    else
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    addr = get_in(state.peers, [pid, :address])

    state =
      state
      |> update_in([:peers], &Map.delete(&1, pid))
      |> update_in([:by_address], &Map.delete(&1, addr))

    {:noreply, state}
  end

  defp add(nil, n), do: n
  defp add(c, n), do: c + n
end
