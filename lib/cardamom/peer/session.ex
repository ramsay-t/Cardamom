defmodule Cardamom.Peer.Session do
  @moduledoc """
  Orchestrates one peer connection end-to-end: connect → **handshake first** →
  then start the mini-protocol processes over the SAME channel.

  The handshake is mandatory and runs to completion before anything else; if it is
  refused the session stops and no protocols start (matching the real node). On
  success we start, in order and linked:

    1. `Cardamom.Connection` — the BEARER (owns the socket; routes by proto#);
    2. `Cardamom.ChainSync.Client` (proto 2) — drives chain-sync;
    3. `Cardamom.KeepAlive.Client` (proto 8) — pings so we aren't reaped at 97s.

  Each protocol process holds the bearer pid and registers itself for its proto#.
  Order matters for a polite shutdown: the bearer starts first, so on teardown the
  protocol processes (started after, linked) die first and get to send their
  `MsgDone` via the bearer before the bearer releases the socket.

  The channel is injected, so this is sim-tested against `Cardamom.SimPeer` and
  becomes a real connection by passing a `Channel.Tcp` — "just the TCP".
  """

  use GenServer
  require Logger

  alias Cardamom.Protocol.Handshake.Client

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)
    peer = Keyword.get(opts, :peer, "unknown")
    magic = Keyword.fetch!(opts, :magic)
    versions = Keyword.get(opts, :versions, [14])
    ledger = Keyword.get(opts, :ledger, {Cardamom.Ledger.Stub, nil})
    keepalive_ms = Keyword.get(opts, :keepalive_ms, 10_000)
    # Which mini-protocols to run THIS session. Every protocol is independently
    # toggleable on boot (config-driven via Node; or an explicit :protocols opt for
    # tests/diagnostics). Default: the chain-following set. The OBSERVATIONAL protocols
    # (peer_sharing, tx_submission) are OFF by default — turning them on is a deliberate
    # config choice (observe-don't-act). Each protocol is independent; an omitted one
    # simply means no traffic for that proto# on the mux.
    protocols = Keyword.get(opts, :protocols, default_protocols())
    peer_store = Keyword.get(opts, :peer_store)

    Process.flag(:trap_exit, true)

    case Client.run(channel, magic: magic, versions: versions) do
      {:ok, agreed} ->
        Logger.info("handshake ok peer=#{peer} version=#{agreed.version} protocols=#{inspect(protocols)}")

        # Bearer first (owns the socket), then the mini-protocol processes that hold its
        # pid. All linked → the session reflects their fate; a clean shutdown propagates
        # so each protocol's terminate/2 sends its goodbye.
        {:ok, conn} =
          Cardamom.Connection.start_link(channel: channel, peer: peer, version: agreed.version)

        ctx = %{
          conn: conn,
          peer: peer,
          ledger: ledger,
          keepalive_ms: keepalive_ms,
          peer_store: peer_store
        }

        # Uniform start: for each ENABLED protocol, start its client and keep the pid
        # (or nil). The order here is also the START order; teardown reverses it.
        clients =
          for {name, _} <- protocol_specs(), into: %{} do
            {name, if(name in protocols, do: start_protocol(name, ctx), else: nil)}
          end

        {:ok, %{channel: channel, peer: peer, agreed: agreed, conn: conn, clients: clients}}

      {:error, reason} ->
        Logger.info("handshake refused peer=#{peer} reason=#{inspect(reason)}")
        {:stop, {:handshake_refused, reason}}
    end
  end

  # The protocol registry: name → start function. Adding a protocol = one entry here.
  # Order is start order (teardown reverses it; keep_alive/chain_sync send goodbyes).
  defp protocol_specs do
    [
      chain_sync: &start_chain_sync/1,
      keep_alive: &start_keep_alive/1,
      block_fetch: &start_block_fetch/1,
      peer_sharing: &start_peer_sharing/1,
      tx_submission: &start_tx_submission/1
    ]
  end

  @doc "The default-enabled protocols when none are specified (chain-following set)."
  def default_protocols, do: [:chain_sync, :keep_alive, :block_fetch]

  @doc "Every protocol Session knows how to start (for config validation / docs)."
  def known_protocols, do: Enum.map(protocol_specs(), &elem(&1, 0))

  defp start_protocol(name, ctx) do
    {^name, fun} = Enum.find(protocol_specs(), fn {n, _} -> n == name end)
    fun.(ctx)
  end

  defp start_chain_sync(%{conn: conn, peer: peer, ledger: ledger}) do
    {:ok, cs} = Cardamom.ChainSync.Client.start_link(conn: conn, peer: peer, ledger: ledger)
    cs
  end

  defp start_keep_alive(%{conn: conn, keepalive_ms: ms}) do
    {:ok, ka} = Cardamom.KeepAlive.Client.start_link(conn: conn, interval_ms: ms)
    ka
  end

  defp start_block_fetch(%{conn: conn, peer: peer}) do
    {:ok, bf} = Cardamom.BlockFetch.Client.start_link(conn: conn, peer: peer)
    # Register into ChainStore's round-robin so get_blocks can fetch from this peer.
    if Process.whereis(Cardamom.ChainStore), do: Cardamom.ChainStore.register_peer(bf)
    bf
  end

  defp start_peer_sharing(%{conn: conn, peer: peer, peer_store: store}) do
    {:ok, ps} = Cardamom.PeerSharing.Client.start_link(conn: conn, peer: peer, peer_store: store)
    ps
  end

  defp start_tx_submission(%{conn: conn, peer: peer}) do
    # Receiver role: pull the peer's mempool txs IN (observe). Submitter side responds
    # if asked. (Full node someday runs both; receiver is the observe path.)
    {:ok, ts} = Cardamom.TxSubmission.Client.start_link(conn: conn, peer: peer, role: :receiver)
    ts
  end

  # A linked child exited. Mirror its fate so the whole session subtree unwinds
  # together (and a clean reason lets each child's terminate/2 say its goodbye).
  @impl true
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  # Ordered, race-free shutdown. On a CLEAN stop we tear down the mini-protocol
  # processes FIRST (each synchronously, so its terminate/2 sends MsgDone and the
  # bearer — still alive — writes it to the wire), and only THEN the bearer, which
  # releases the socket. Stopping them in reverse start-order. On an abnormal reason
  # we skip the politeness and let the links drop everything.
  @impl true
  def terminate(reason, state) do
    if clean?(reason) do
      # NARRATE the close: this is the citizenship-critical path, so each step logs.
      # A silent teardown means we can't prove (from the log) that we left politely.
      # Tear down the protocol clients in REVERSE start order (so each sends its goodbye
      # via the still-alive bearer), then the bearer last.
      Logger.info("shutdown peer=#{state.peer}: clean (reason=#{inspect(reason)}) — tearing down in order")

      known_protocols()
      |> Enum.reverse()
      |> Enum.each(fn name -> stop_child(to_string(name), state.clients[name]) end)

      stop_child("bearer (closes socket)", state.conn)
      Logger.info("shutdown peer=#{state.peer}: complete — socket released, goodbyes sent")
    else
      Logger.info("shutdown peer=#{state.peer}: abnormal (reason=#{inspect(reason)}) — releasing without goodbye")
    end

    :ok
  end

  defp clean?(:normal), do: true
  defp clean?(:shutdown), do: true
  defp clean?({:shutdown, _}), do: true
  defp clean?(_), do: false

  # Synchronous stop so the child's terminate/2 completes before we move on (the
  # MsgDone write happens while the bearer is still up). Bounded; ignore if already
  # gone. :shutdown is a clean reason for the child too. Logs each step.
  defp stop_child(_label, nil), do: :ok

  defp stop_child(label, pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Logger.info("  shutdown step: stopping #{label} #{inspect(pid)}")
      GenServer.stop(pid, :shutdown, 2_000)
      Logger.info("  shutdown step: #{label} stopped")
    else
      Logger.info("  shutdown step: #{label} already down")
    end

    :ok
  catch
    kind, err ->
      Logger.warning("  shutdown step: #{label} #{kind} #{inspect(err)} (continuing)")
      :ok
  end
end
