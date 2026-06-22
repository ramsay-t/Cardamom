# BLOCK-FETCH-ONLY live probe — chain-sync OFF, so the captured traffic on the mux
# is unambiguously block-fetch (proto 3) + a little keep-alive (proto 8). Gives Marcin
# a clean pcap: just the RequestRange → StartBatch → MsgBlock* → (BatchDone?) exchange,
# with no chain-sync (proto 2) RollForward stream interleaved.
#
#   RUN_FROM=200 RUN_COUNT=200 mix run run_blockfetch_only.exs
#
# Requires forest-2.db already populated with >= FROM+COUNT headers (the points we
# request). Block-fetch resolves those points; it does NOT need chain-sync running.

require Logger
alias Cardamom.{ChainStore, Node}

Process.flag(:trap_exit, true)
from = String.to_integer(System.get_env("RUN_FROM", "200"))
count = String.to_integer(System.get_env("RUN_COUNT", "200"))

if Process.whereis(Cardamom.DevFakePeer) do
  Logger.error("ABORT: loopback running — would contaminate. Don't set CARDAMOM_LOOPBACK.")
  System.stop(1)
  Process.sleep(:infinity)
end

points =
  ChainStore.all_headers()
  |> Enum.drop(from)
  |> Enum.take(count)
  |> Enum.map(fn h -> [h.slot, h.hash] end)

if points == [] do
  Logger.error("no stored headers in range — populate forest-2.db with a chain-sync run first")
  System.stop(1)
  Process.sleep(:infinity)
end

Logger.info("=== BLOCKFETCH-ONLY PROBE === chain-sync OFF; fetching #{length(points)} block points (#{from}..#{from + count - 1})")

# Block-fetch-only session: no chain-sync. Keep-alive stays so the relay doesn't reap
# us during the (deliberately long) range.
case Node.start(config_file: "config/preview.json", protocols: [:block_fetch, :keep_alive]) do
  {:ok, session} ->
    Logger.info("=== node up (session #{inspect(session)}); waiting for block-fetch peer to register ===")

    # Pipe-live signal WITHOUT chain-sync: a block-fetch client registered in
    # ChainStore's rotation (handshake done, bearer up, proto 3 ready). Poll with a
    # deadline — no blind sleep.
    deadline = System.monotonic_time(:millisecond) + 15_000

    wait = fn wait ->
      cond do
        ChainStore.peers() != [] -> :ok
        System.monotonic_time(:millisecond) > deadline -> :timeout
        true -> (Process.sleep(100); wait.(wait))
      end
    end

    case wait.(wait) do
      :ok -> Logger.info("=== block-fetch peer registered (peers=#{length(ChainStore.peers())}) — commanding get_blocks ===")
      :timeout -> Logger.error("=== block-fetch peer NOT registered within 15s — fetch will be unavailable ===")
    end

    results = ChainStore.get_blocks(points)

    ok = Enum.count(results, &match?({:ok, _}, &1))
    unavail = Enum.count(results, &match?({:unavailable, _}, &1))
    Logger.info("=== RESULT: #{ok}/#{length(points)} fetched + body-hash VERIFIED (#{unavail} unavailable) ===")

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

Logger.info("=== BLOCKFETCH-ONLY PROBE END ===")
Process.sleep(500)
System.stop(0)
