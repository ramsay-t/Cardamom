# One-shot LIVE block-fetch probe via the REAL node path.
#
# Spins up a Cardamom node (Node.start → one Channel to Preview → handshake →
# chain-sync + keep-alive + a dormant block-fetch client registered with ChainStore),
# then commands ChainStore.get_blocks for the first N stored block points (0..N-1).
# ChainStore round-robins to the registered peer, block-fetches the range, LOGS the
# raw bytes (:debug), verifies each body against its header's block_body_hash, stores
# the valid ones, and returns self-describing results. Then a clean shutdown.
#
#   RUN_FIRST=6 mix run --no-halt run_blockfetch_oneshot.exs
#
# GROUND TRUTH: if verify_body passes on real Preview blocks, our body-hash spec
# (reverse-engineered from the Haskell) is correct.

require Logger
alias Cardamom.{ChainStore, Node}

Process.flag(:trap_exit, true)
# RUN_FROM = first block_no (default 0), RUN_COUNT = how many (default RUN_FIRST or 6).
# So RUN_FROM=100 RUN_COUNT=50 requests blocks 100..149 — a clean cap test on unstored
# blocks (no cache hits muddying where the relay's per-range limit bites).
from = String.to_integer(System.get_env("RUN_FROM", "0"))
count = String.to_integer(System.get_env("RUN_COUNT", System.get_env("RUN_FIRST", "6")))

if Process.whereis(Cardamom.DevFakePeer) do
  Logger.error("ABORT: loopback running — would contaminate. Don't set CARDAMOM_LOOPBACK.")
  System.stop(1)
  Process.sleep(:infinity)
end

# Stored header points (slot-ordered), the slice [from .. from+count-1] by position.
points =
  ChainStore.all_headers()
  |> Enum.drop(from)
  |> Enum.take(count)
  |> Enum.map(fn h -> [h.slot, h.hash] end)

if points == [] do
  Logger.error("no stored headers — run a chain-sync session first to populate forest-2.db")
  System.stop(1)
  Process.sleep(:infinity)
end

Logger.info("=== BLOCKFETCH PROBE === will fetch bodies for first #{length(points)} stored blocks (0..#{length(points) - 1})")

# Wait until the pipe is provably LIVE before commanding a fetch: (a) a block-fetch
# peer is registered in ChainStore's rotation (else get_blocks → :unavailable), AND
# (b) chain-sync is actually flowing (a RollForward seen → the bearer carries traffic,
# not just handshaked). Telemetry sends to THIS process; we poll its mailbox with a
# deadline — no blind sleep, no Task (the mailbox is here).
me = self()

:telemetry.attach(
  "bf-probe-cs",
  [:cardamom, :protocol, :event],
  fn _e, _m, %{msg: msg}, _ -> if msg in ["RollForward", "RollBackward"], do: send(me, :chain_sync_live) end,
  nil
)

# Returns :ok once peer-registered AND chain-sync seen, or :timeout at the deadline.
wait_live = fn wait_live, cs_seen, deadline ->
  cs_seen =
    cs_seen or
      receive do
        :chain_sync_live -> true
      after
        0 -> false
      end

  cond do
    ChainStore.peers() != [] and cs_seen -> :ok
    System.monotonic_time(:millisecond) > deadline -> :timeout
    true -> (Process.sleep(100); wait_live.(wait_live, cs_seen, deadline))
  end
end

case Node.start(config_file: "config/preview.json") do
  {:ok, session} ->
    Logger.info("=== node up (session #{inspect(session)}); waiting for pipe to go live ===")

    deadline = System.monotonic_time(:millisecond) + 15_000
    pipe = wait_live.(wait_live, false, deadline)
    :telemetry.detach("bf-probe-cs")

    if pipe == :timeout,
      do: Logger.error("=== pipe NOT live within 15s (peers=#{length(ChainStore.peers())}) — fetch may be unavailable ===")

    Logger.info("=== pipe live: ChainStore peers=#{length(ChainStore.peers())} ===")

    # Pipe is live (we saw a chain-sync message) — fetch the blocks NOW. Chain-sync
    # keeps running concurrently in the background (bonus DB-filling); the 100 blocks
    # are the goal.
    Logger.info("=== commanding ChainStore.get_blocks for #{length(points)} points ===")
    results = ChainStore.get_blocks(points)

    Enum.zip(points, results)
    |> Enum.each(fn {[slot, hash], res} ->
      short = Base.encode16(hash, case: :lower) |> String.slice(0, 12)

      tag =
        case res do
          {:ok, row} -> "OK — body VERIFIED (tx_count=#{row.tx_count}, #{byte_size(row.raw)}B)"
          {:rejected, _} -> "REJECTED — body-hash mismatch (spec wrong OR peer lied)"
          {:unavailable, _} -> "unavailable (relay didn't serve it)"
        end

      Logger.info("  block slot=#{slot} #{short}: #{tag}")
    end)

    ok = Enum.count(results, &match?({:ok, _}, &1))
    Logger.info("=== RESULT: #{ok}/#{length(points)} blocks fetched + body-hash VERIFIED ===")

    Logger.info("=== commanding clean shutdown ===")

    try do
      GenServer.stop(session, :shutdown, 5_000)
      Logger.info("=== clean shutdown complete ===")
    catch
      kind, err -> Logger.warning("=== shutdown #{kind}: #{inspect(err)} ===")
    end

  {:error, reason} ->
    Logger.error("=== node failed to start: #{inspect(reason)} ===")
end

Logger.info("=== BLOCKFETCH PROBE END ===")
Process.sleep(500)
System.stop(0)
