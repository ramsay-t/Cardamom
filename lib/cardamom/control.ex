defmodule Cardamom.Control do
  @moduledoc """
  The single addressable command hub for the node. Access functions (in
  `Cardamom`) message this registered process; it knows the topology and
  orchestrates clean shutdowns.

  It is `:permanent` and crashes-are-fine (the Armstrong model): if it dies the
  supervisor restarts it, and it rediscovers the topology on `init` rather than
  relying on in-memory references that died with it.

  Shutdown philosophy (see CLAUDE_NOTES / security.md): Control *initiates and
  observes*, it does NOT coordinate acks. Graceful disconnect = ask the relevant
  supervisor to terminate the peer subtree; the polite `MsgDone` lives in each
  Connection's `terminate/2` (OTP-native), bounded by the child shutdown timeout.
  Control never re-implements the supervisor's shutdown state machine.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # ---- access API (also exposed via the `Cardamom` module) ----

  @doc "Snapshot of what Control knows: connected peers (rediscovered live)."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Gracefully disconnect all peers: terminate the peer subtree so each Connection's
  terminate/2 sends its MsgDone and closes, with no restart (it's a commanded
  shutdown, not a crash). Bounded by the children's shutdown timeouts.
  """
  def disconnect_all, do: GenServer.call(__MODULE__, :disconnect_all, 30_000)

  @doc "Graceful disconnect of all peers, then stop the whole node."
  def shutdown do
    disconnect_all()
    System.stop(0)
    :ok
  end

  @doc """
  Politeness gate: may we dial `{host, port}` now? `:ok` to proceed (the attempt
  is recorded), or `{:wait, ms}` to back off. Report the outcome with
  `report_connected/2` / `report_disconnected/2` / `report_failed/2`.
  """
  def request_connect(host, port), do: GenServer.call(__MODULE__, {:request_connect, {host, port}})
  def report_connected(host, port), do: GenServer.cast(__MODULE__, {:conn_result, :connected, {host, port}})
  def report_disconnected(host, port), do: GenServer.cast(__MODULE__, {:conn_result, :disconnected, {host, port}})
  def report_failed(host, port), do: GenServer.cast(__MODULE__, {:conn_result, :failed, {host, port}})

  # ---- GenServer ----

  @impl true
  def init(opts) do
    # Topology is rediscovered, not held across restarts. peer_supervisor is the
    # DynamicSupervisor owning peer-session subtrees (injectable for tests).
    policy = Keyword.get(opts, :policy) || Cardamom.ConnectPolicy.new()
    {:ok, %{peer_supervisor: Keyword.get(opts, :peer_supervisor), policy: policy}}
  end

  @impl true
  def handle_call({:request_connect, ep}, _from, state) do
    case Cardamom.ConnectPolicy.allow(state.policy, ep, now_ms: now_ms()) do
      {:ok, policy} -> {:reply, :ok, %{state | policy: policy}}
      {:wait, ms, policy} -> {:reply, {:wait, ms}, %{state | policy: policy}}
    end
  end

  def handle_call(:status, _from, state) do
    peers = if Process.whereis(Cardamom.Peers), do: Cardamom.Peers.list(), else: []
    {:reply, %{peers: peers, peer_count: length(peers)}, state}
  end

  def handle_call(:disconnect_all, _from, %{peer_supervisor: sup} = state) when not is_nil(sup) do
    # Gracefully terminate each peer subtree. terminate_child fires the children's
    # terminate/2 (polite MsgDone) and does NOT restart them.
    children =
      sup
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_, pid, _, _} -> pid end)
      |> Enum.filter(&is_pid/1)

    Enum.each(children, fn pid -> DynamicSupervisor.terminate_child(sup, pid) end)
    {:reply, {:ok, length(children)}, state}
  end

  def handle_call(:disconnect_all, _from, state) do
    # No peer supervisor wired (e.g. observer not started) — nothing to disconnect.
    {:reply, {:ok, 0}, state}
  end

  @impl true
  def handle_cast({:conn_result, kind, ep}, state) do
    fun =
      %{
        connected: &Cardamom.ConnectPolicy.connected/3,
        disconnected: &Cardamom.ConnectPolicy.disconnected/3,
        failed: &Cardamom.ConnectPolicy.failed/3
      }[kind]

    {:noreply, %{state | policy: fun.(state.policy, ep, now_ms: now_ms())}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
