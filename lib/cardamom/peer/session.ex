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

    Process.flag(:trap_exit, true)

    case Client.run(channel, magic: magic, versions: versions) do
      {:ok, agreed} ->
        Logger.info("handshake ok peer=#{peer} version=#{agreed.version}")

        # Bearer first (owns the socket), then the mini-protocol processes that
        # hold its pid. All linked → the session reflects their fate, and a clean
        # session shutdown propagates so each protocol's terminate/2 sends MsgDone.
        {:ok, conn} =
          Cardamom.Connection.start_link(channel: channel, peer: peer, version: agreed.version)

        {:ok, chain_sync} =
          Cardamom.ChainSync.Client.start_link(conn: conn, peer: peer, ledger: ledger)

        {:ok, keep_alive} =
          Cardamom.KeepAlive.Client.start_link(conn: conn, interval_ms: keepalive_ms)

        {:ok, block_fetch} =
          Cardamom.BlockFetch.Client.start_link(conn: conn, peer: peer)

        # Register this peer's block-fetch client into ChainStore's round-robin, so
        # ChainStore.get_blocks can fetch from it. Best-effort (absent in bare tests).
        if Process.whereis(Cardamom.ChainStore), do: Cardamom.ChainStore.register_peer(block_fetch)

        {:ok,
         %{
           channel: channel,
           peer: peer,
           agreed: agreed,
           conn: conn,
           chain_sync: chain_sync,
           keep_alive: keep_alive,
           block_fetch: block_fetch
         }}

      {:error, reason} ->
        Logger.info("handshake refused peer=#{peer} reason=#{inspect(reason)}")
        {:stop, {:handshake_refused, reason}}
    end
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
      Logger.info("shutdown peer=#{state.peer}: clean (reason=#{inspect(reason)}) — tearing down in order")
      stop_child("keep_alive", state.keep_alive)
      stop_child("block_fetch", state.block_fetch)
      stop_child("chain_sync (sends MsgDone)", state.chain_sync)
      stop_child("bearer (closes socket)", state.conn)
      Logger.info("shutdown peer=#{state.peer}: complete — socket released, MsgDone sent")
    else
      Logger.info("shutdown peer=#{state.peer}: abnormal (reason=#{inspect(reason)}) — releasing without MsgDone")
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
