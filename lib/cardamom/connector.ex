defmodule Cardamom.Connector do
  @moduledoc """
  Dials the boot peer(s) when the node starts — the piece that makes a RELEASE actually
  connect (before this, connections only ever came from a manual Node.start in a script,
  so a released `bin/cardamom` booted and sat idle). Reads the resolved config: if
  `connect: true`, it starts a Peer.Session to `first_peer` over a real TCP channel, using
  the configured network + protocols. Best-effort and non-fatal: a failed dial logs and
  the node stays up (it can be retried / will reconnect logic later).

  This is a thin boot hook, not a connection manager — the multi-peer / reconnect / trust
  layer is a separate future build. For now: one boot peer from the params file.
  """
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Dial after init returns, so the supervision tree is fully up first.
    {:ok, %{}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:ok, cfg} = Cardamom.Config.resolve(config_opts())

    if cfg.connect do
      %{host: host, port: port} = cfg.first_peer
      Logger.info("connector: dialing boot peer #{host}:#{port} (protocols=#{inspect(cfg.protocols)})")

      # Start the session UNDER the PeerSupervisor (not dangling off us), so app shutdown
      # terminates it GRACEFULLY (its terminate/2 sends MsgDone before the socket closes).
      case Cardamom.Node.start_supervised(node_opts(cfg)) do
        {:ok, _session} -> Logger.info("connector: session up to #{host}:#{port}")
        other -> Logger.warning("connector: boot dial failed: #{inspect(other)} (node stays up)")
      end
    else
      Logger.info("connector: connect=false — store-only boot, not dialing")
    end

    {:noreply, state}
  end

  # Pass the file through to Node.start so it resolves the SAME config (network, peer,
  # protocols) the connector saw.
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
