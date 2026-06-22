defmodule Cardamom.BlockFetch.GetBlocksFanoutTest do
  @moduledoc """
  Fan-out under concurrent load: 5 SimPeers (each serving the full block set) registered
  in ChainStore's round-robin, then 50 CONCURRENT processes each calling get_blocks on a
  different 10-block range. Proves the per-peer stacks + the round-robin rotation handle
  genuine parallel demand correctly — every block fetched, body-verified, stored, with no
  cross-talk between concurrent callers — and that work actually spreads across all 5
  peers (not all funnelled to one).

  This is the consumer-shaped load: many independent block requests arriving at once
  (e.g. resolving many UTXOs), which is exactly what round-robin is for — NOT striping a
  single contiguous range (one range correctly goes to one peer as one fast batch).
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{Channel, ChainStore, Connection, BlockFetch}
  alias Cardamom.Ledger.Conway.BlockBuilder
  alias Cardamom.Store.Block, as: BlockRow

  @peers 5
  @ranges 50
  @per_range 10
  @total @ranges * @per_range

  # Register one SimPeer serving `blocks`, behind a real bearer + block-fetch client.
  # Returns the peer label (for observing which peers served traffic via telemetry).
  defp register_sim(blocks, label) do
    {client_end, server_end} = Channel.Test.pair()
    {:ok, _sim} = Cardamom.SimPeer.start_link(channel: server_end, protocols: [:block_fetch], blocks: blocks)
    {:ok, conn} = Connection.start_link(channel: client_end, peer: label)
    {:ok, bf} = BlockFetch.Client.start_link(conn: conn, peer: label)
    :ok = ChainStore.register_peer(bf)
    label
  end

  test "50 concurrent get_blocks (10 blocks each) across 5 peers: all fetched, verified, stored" do
    # 500 real-shaped blocks at slots 1..500 (each with a correct body-hash commitment).
    blocks = for sl <- 1..@total, do: BlockBuilder.build(block_number: sl, slot: sl, tx_count: 1)

    # Fresh rotation; register 5 peers, EACH holding all 500 blocks (any peer can serve
    # any range — so correctness can't depend on which peer a range lands on).
    ChainStore.reset_peers()
    labels = for i <- 1..@peers, do: register_sim(blocks, "peer-#{i}")

    # Observe which peers actually served blocks (prove the load spread, not funnelled).
    test_pid = self()

    :telemetry.attach(
      "fanout-observe",
      [:cardamom, :protocol, :event],
      fn _e, _m, meta, _ ->
        # Defensive: not every protocol event carries :peer/:msg — only count the
        # block-fetch BlockReceived ones, ignore the rest.
        if meta[:msg] == "BlockReceived" and is_binary(meta[:peer]),
          do: send(test_pid, {:served_by, meta[:peer]})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("fanout-observe") end)

    # 50 ranges of 10 consecutive slots: 1..10, 11..20, … 491..500.
    ranges =
      for r <- 0..(@ranges - 1) do
        Enum.map(1..@per_range, fn k ->
          sl = r * @per_range + k
          b = Enum.at(blocks, sl - 1)
          [b.slot, b.header_hash]
        end)
      end

    # Fire all 50 get_blocks calls CONCURRENTLY — independent processes, shared
    # ChainStore + 5-peer rotation. A generous timeout: 500 blocks is ~1s of real work,
    # but in-process SimPeers are faster.
    results =
      ranges
      |> Task.async_stream(fn pts -> ChainStore.get_blocks(pts) end,
        max_concurrency: @ranges,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, res} -> res end)

    # Every range returned 10 {:ok, block} in request order.
    assert length(results) == @ranges

    for res <- results do
      assert length(res) == @per_range
      assert Enum.all?(res, &match?({:ok, %BlockRow{}}, &1)), "every block in every range fetched + verified"
    end

    # All 500 distinct blocks are durably stored.
    stored = for b <- blocks, do: ChainStore.stored_block(b.header_hash)
    assert Enum.all?(stored, &match?(%BlockRow{}, &1)), "all 500 blocks stored"
    assert length(Enum.uniq_by(stored, & &1.slot)) == @total, "no duplicates / no gaps"

    # The work genuinely spread across peers — collect the distinct peers that served at
    # least one block. With 50 ranges round-robined over 5 peers, all 5 must appear.
    served = drain_served(MapSet.new())
    assert MapSet.size(served) == @peers, "all #{@peers} peers served traffic (got: #{inspect(MapSet.to_list(served))})"
    assert MapSet.subset?(served, MapSet.new(labels))
  end

  defp drain_served(acc) do
    receive do
      {:served_by, peer} -> drain_served(MapSet.put(acc, peer))
    after
      0 -> acc
    end
  end
end
