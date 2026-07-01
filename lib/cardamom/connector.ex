defmodule Cardamom.Connector do
  @moduledoc """
  Dials the boot peer when the node starts, AND keeps the connection up: if the session ends
  (a drop, a keep-alive dead-peer timeout, an RST after a laptop sleep), the Connector redials
  after a backoff. This is what makes the node RESILIENT — without it, one network blip left
  Cardamom connected to nothing until a manual restart.

  How: it starts a `Peer.Session` under `PeerSupervisor`, MONITORs that session pid, and on
  `:DOWN` schedules a reconnect using `Cardamom.ConnectPolicy`'s exponential backoff (10s base,
  300s cap; reset on a successful connect). On node shutdown the supervisor terminates the
  Connector itself, so its monitor never fires a redial that would fight the graceful stop.

  Still a SINGLE-peer manager (the multi-peer / trust layer is a later build). `connect: false`
  in the params makes it a store-only boot (no dialing, no reconnect).
  """
  use GenServer
  require Logger

  alias Cardamom.ConnectPolicy

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, cfg} = Cardamom.Config.resolve(config_opts())
    state = %{cfg: cfg, session: nil, ref: nil, policy: ConnectPolicy.new()}
    # Dial after init returns, so the supervision tree is fully up first.
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{cfg: %{connect: false}} = state) do
    Logger.info("connector: connect=false — store-only boot, not dialing")
    {:noreply, state}
  end

  def handle_continue(:connect, state), do: {:noreply, dial(state)}

  # Backoff timer fired — try again.
  @impl true
  def handle_info(:reconnect, state), do: {:noreply, dial(state)}

  # The session we were monitoring went down (drop / keep-alive timeout / RST). Record the
  # disconnect (grows backoff) and try again — `dial` consults the policy and re-arms the timer
  # if it's too soon. (On node shutdown we're terminated first, so this won't fire then.)
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = state) do
    %{host: host, port: port} = state.cfg.first_peer
    Logger.warning("connector: session to #{host}:#{port} ended (#{inspect(reason)}) — reconnecting")
    policy = ConnectPolicy.disconnected(state.policy, {host, port}, now_ms: now_ms())
    {:noreply, dial(%{state | session: nil, ref: nil, policy: policy})}
  end

  # A stale DOWN (from a session we already replaced) — ignore.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # The single dial gate: ask the policy if we may connect now. If not, arm a timer for the
  # remaining backoff. If yes, open a session + monitor it (reset backoff on success; grow it on
  # failure and retry).
  defp dial(state) do
    %{host: host, port: port} = state.cfg.first_peer

    case ConnectPolicy.allow(state.policy, {host, port}, now_ms: now_ms()) do
      {:wait, ms, policy} ->
        Logger.info("connector: next dial of #{host}:#{port} in #{ms}ms (backoff)")
        Process.send_after(self(), :reconnect, ms)
        %{state | policy: policy}

      {:ok, policy} ->
        Logger.info("connector: dialing #{host}:#{port} (protocols=#{inspect(state.cfg.protocols)})")

        case Cardamom.Node.start_supervised(node_opts(state.cfg)) do
          {:ok, session} ->
            Logger.info("connector: session up to #{host}:#{port}")
            ref = Process.monitor(session)
            policy = ConnectPolicy.connected(policy, {host, port}, now_ms: now_ms())
            %{state | session: session, ref: ref, policy: policy}

          other ->
            Logger.warning("connector: dial failed: #{inspect(other)} — backing off")
            policy = ConnectPolicy.failed(policy, {host, port}, now_ms: now_ms())
            # Retry via the policy gate (it now returns a wait, which arms the timer).
            dial(%{state | policy: policy})
        end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Pass the file through to Node.start so it resolves the SAME config (network, peer, protocols).
  defp node_opts(cfg) do
    base = [protocols: cfg.protocols]

    case System.get_env("CARDAMOM_CONFIG") do
      nil -> base ++ [first_peer: cfg.first_peer, network: cfg.network]
      file -> base ++ [config_file: file]
    end
  end

  defp config_opts do
    case System.get_env("CARDAMOM_CONFIG") do
      nil -> []
      file -> [config_file: file]
    end
  end
end
