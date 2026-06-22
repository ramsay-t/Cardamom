# One-shot, observed, polite Preview connection.
#
# Safe by construction: ONE connection, NOT under the auto-restarting supervision
# tree (so a mid-run crash can't trigger a reconnect loop), a hard time box, then
# a graceful disconnect (terminate/2 sends chain-sync MsgDone). Everything logs to
# log/cardamom.log (file handler attached by the app on boot).
#
# Run with:  mix run --no-halt run_preview_oneshot.exs
#   RUN_SECONDS    overrides the 60s default.
#   CARDAMOM_SESSION  names the per-session log file
#                     (log/cardamom-<ts>-<name>.log). Logs are NEVER deleted —
#                     each run is its own file for later comparison.

require Logger

# Trap exits: stopping the session sends a :shutdown signal down our links, which
# would kill THIS script before it reaches its own clean System.stop(0) — exiting 1
# mid-shutdown and never logging the graceful-close confirmation. Trapping turns
# those signals into messages we ignore, so the script controls its own shutdown.
Process.flag(:trap_exit, true)

run_seconds = String.to_integer(System.get_env("RUN_SECONDS", "60"))

# A live capture must contain ONLY real Preview traffic — no synthetic DevFakePeer
# loopback mixed into the forest/event counts. The loopback defaults ON in :dev (the
# env `mix run` uses), so we ASSERT it is off here rather than trusting the operator
# to remember CARDAMOM_NO_LOOPBACK. If it slipped through, abort loudly — a polluted
# capture is worse than no capture.
if Process.whereis(Cardamom.DevFakePeer) do
  Logger.error(
    "=== ABORT: DevFakePeer loopback is RUNNING — capture would be contaminated. " <>
      "The loopback is opt-in now; do NOT set CARDAMOM_LOOPBACK for a live capture. ==="
  )

  System.stop(1)
  Process.sleep(:infinity)
end

Logger.info("=== PREVIEW ONE-SHOT START === run_seconds=#{run_seconds} (loopback off, clean capture) ===")

# Start ONE connection to Preview (defaults / preview.json => the IOG bootstrap
# relay, magic 2). Channel.Tcp -> Peer.Session (handshake -> chain-sync||keepalive).
case Cardamom.Node.start(config_file: "config/preview.json") do
  {:ok, session} ->
    Logger.info("=== session started pid=#{inspect(session)} — observing for #{run_seconds}s ===")
    ref = Process.monitor(session)

    # Periodic forest snapshot so we get a forest narrative in the log.
    snapshot = fn ->
      if Process.whereis(Cardamom.Forest.Server) do
        s = Cardamom.Forest.Server.status()
        Logger.info("=== FOREST: tip=#{inspect(s.tip) |> String.slice(0, 24)} height=#{inspect(s.tip_height)} nodes=#{s.node_count} ===")
      end
    end

    snap_timer = :timer.apply_interval(15_000, fn -> snapshot.() end)

    # Wait up to run_seconds, but also notice if the session dies on its own
    # (e.g. handshake refused, relay dropped us) so we log that and stop early.
    receive do
      {:DOWN, ^ref, :process, ^session, reason} ->
        Logger.warning("=== session ended early reason=#{inspect(reason)} ===")
    after
      run_seconds * 1000 ->
        Logger.info("=== time box reached — disconnecting gracefully ===")
        snapshot.()
        # Polite close: GenServer.stop(:shutdown) fires terminate/2 -> MsgDone.
        try do
          GenServer.stop(session, :shutdown, 5000)
          Logger.info("=== graceful disconnect complete ===")
        catch
          kind, err -> Logger.warning("=== shutdown #{kind}: #{inspect(err)} ===")
        end
    end

    case snap_timer do
      {:ok, t} -> :timer.cancel(t)
      _ -> :ok
    end
    snapshot.()

  {:error, reason} ->
    Logger.error("=== could not connect reason=#{inspect(reason)} ===")
end

Logger.info("=== PREVIEW ONE-SHOT END ===")
# Give the file logger a moment to flush, then stop the VM cleanly.
Process.sleep(1000)
System.stop(0)
