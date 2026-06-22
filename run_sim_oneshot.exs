# One-shot LOCAL SimPeer run, for watching the UI fill — NO live network.
#
# Listens on an ephemeral localhost port, accepts ONE connection into a SimPeer
# (handshake -> chain-sync -> keep-alive responder, serving an endless real-shaped
# header chain consumer-paced), then dials it via the real Node.start entry point.
# The whole receive/parse/forest pipeline runs for real over loopback TCP. Time-boxed,
# then graceful disconnect (GenServer.stop(:shutdown) -> terminate/2 -> MsgDone).
#
# Run with:  mix run --no-halt run_sim_oneshot.exs   (RUN_SECONDS overrides 60)
# Watch the UI at http://localhost:4001 — the Forest panel climbs.

require Logger
alias Cardamom.{Channel, SimPeer, Node}

# Trap exits: stopping the session (and the linked acceptor) sends a :shutdown signal
# down our links. Without trapping, that signal kills THIS script before it reaches its
# own clean System.stop(0) — the script exits 1 mid-shutdown instead of completing the
# graceful disconnect. Trapping turns those signals into messages we can ignore.
Process.flag(:trap_exit, true)

run_seconds = String.to_integer(System.get_env("RUN_SECONDS", "60"))

# The SimPeer is purely local, so the loopback contamination concern doesn't apply
# (there's no real capture here) — but we still keep DevFakePeer off so the topology
# shows exactly ONE connection: our SimPeer.
if Process.whereis(Cardamom.DevFakePeer) do
  Logger.warning("DevFakePeer loopback is running — topology will show an extra connection")
end

{:ok, lsock, port} = Channel.Tcp.listen(0)
Logger.info("=== SIM ONE-SHOT === SimPeer listening on localhost:#{port}, run_seconds=#{run_seconds}")

# Acceptor: hand the accepted channel to a SimPeer and keep it alive.
{:ok, acceptor} =
  Task.start_link(fn ->
    {:ok, chan} = Channel.Tcp.accept(lsock, 10_000)
    {:ok, _} = SimPeer.start_link(channel: chan, protocols: [:handshake, :chain_sync, :keep_alive], magic: 2)
    Process.sleep(:infinity)
  end)

# Dial it via the real entry point — the SAME call shape as a Preview run.
case Node.start(first_peer: %{host: "localhost", port: port}, network: 2, db: "sim-db", peer: "sim-peer") do
  {:ok, session} ->
    Logger.info("=== session started pid=#{inspect(session)} — observing for #{run_seconds}s — watch http://localhost:4001 ===")
    ref = Process.monitor(session)

    snapshot = fn ->
      if Process.whereis(Cardamom.Forest.Server) do
        s = Cardamom.Forest.Server.status()
        Logger.info("=== FOREST: tip=#{inspect(s.tip) |> String.slice(0, 24)} height=#{inspect(s.tip_height)} nodes=#{s.node_count} ===")
      end
    end

    {:ok, snap_timer} = :timer.apply_interval(10_000, fn -> snapshot.() end)

    receive do
      {:DOWN, ^ref, :process, ^session, reason} ->
        Logger.warning("=== session ended early reason=#{inspect(reason)} ===")
    after
      run_seconds * 1000 ->
        Logger.info("=== time box reached — disconnecting gracefully ===")
        snapshot.()
        try do
          GenServer.stop(session, :shutdown, 5000)
          Logger.info("=== graceful disconnect complete (MsgDone) ===")
        catch
          kind, err -> Logger.warning("=== shutdown #{kind}: #{inspect(err)} ===")
        end
    end

    :timer.cancel(snap_timer)
    snapshot.()

  {:error, reason} ->
    Logger.error("=== could not start session reason=#{inspect(reason)} ===")
end

if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
:gen_tcp.close(lsock)

Logger.info("=== SIM ONE-SHOT END ===")
Process.sleep(500)
System.stop(0)
