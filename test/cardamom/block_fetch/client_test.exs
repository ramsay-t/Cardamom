defmodule Cardamom.BlockFetch.ClientTest do
  @moduledoc """
  BlockFetch.Client streaming behaviour: each block is handed to a SINK in its own
  process as it arrives; fetch_range returns a COMPLETION signal (:ok / {:error,_}),
  not the blocks. Crucially, completion waits for ALL spawned handlers to FINISH (not
  merely spawn) — for both :ok (BatchDone) AND :error (idle), so a caller reading the
  store afterwards never races a still-running handler.
  """
  use ExUnit.Case, async: false

  alias Cardamom.{Channel, Connection, BlockFetch, Mux.Frame}
  alias Cardamom.Protocol.BlockFetch.Codec, as: BF
  alias Cardamom.Ledger.Conway.BlockBuilder

  @block_fetch 3

  defp scripted do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "bf")
    {:ok, bf} = BlockFetch.Client.start_link(conn: conn, peer: "bf")
    {bf, peer_end}
  end

  defp send_bf(peer_end, msg), do: Frame.send_msg(peer_end, @block_fetch, BF.encode(msg))

  # A sink that forwards each block to THIS test process so we can assert what arrived.
  defp collecting_sink(test_pid), do: fn raw -> send(test_pid, {:sunk, raw}) end

  defp collect_sunk(acc \\ []) do
    receive do
      {:sunk, raw} -> collect_sunk([raw | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "streams each block to the sink; returns :ok on BatchDone" do
    {bf, peer_end} = scripted()
    me = self()
    blk = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 1)

    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [10, blk.header_hash], [10, blk.header_hash], collecting_sink(me)) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    send_bf(peer_end, :start_batch)
    send_bf(peer_end, {:block, blk.envelope})
    send_bf(peer_end, :batch_done)

    assert :ok = Task.await(task, 2_000)
    # The sink ran for the block (and the :ok came AFTER the handler finished).
    assert [raw] = collect_sunk()
    assert raw == blk.raw
  end

  test "NoBlocks reply yields :ok (no blocks sunk)" do
    {bf, peer_end} = scripted()
    me = self()

    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [1, <<1>>], [2, <<2>>], collecting_sink(me)) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    send_bf(peer_end, :no_blocks)

    assert :ok = Task.await(task, 2_000)
    assert [] = collect_sunk()
  end

  test "completion WAITS for a slow handler to finish before replying (no race)" do
    {bf, peer_end} = scripted()
    me = self()
    blk = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 0)

    # A deliberately slow sink: signal start, sleep, then signal done.
    slow_sink = fn _raw ->
      send(me, :handler_started)
      Process.sleep(300)
      send(me, :handler_finished)
    end

    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [10, blk.header_hash], [10, blk.header_hash], slow_sink) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    send_bf(peer_end, :start_batch)
    send_bf(peer_end, {:block, blk.envelope})
    send_bf(peer_end, :batch_done)

    # :ok must arrive only AFTER the handler finished — assert ordering.
    assert_receive :handler_started, 1_000
    assert :ok = Task.await(task, 2_000)
    assert_received :handler_finished, "completion must wait for the handler"
  end

  test "a busy client (request mid-batch) returns {:error, :busy}" do
    {bf, peer_end} = scripted()
    me = self()

    spawn(fn -> BlockFetch.Client.fetch_range(bf, [1, <<1>>], [2, <<2>>], collecting_sink(me)) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    assert {:error, :busy} = BlockFetch.Client.fetch_range(bf, [3, <<3>>], [4, <<4>>], collecting_sink(me), 1_000)
  end

  test "StartBatch + Block + BatchDone packed in ONE SDU drains + streams correctly" do
    {bf, peer_end} = scripted()
    me = self()
    blk = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 0)

    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [10, blk.header_hash], [10, blk.header_hash], collecting_sink(me)) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    packed = BF.encode(:start_batch) <> BF.encode({:block, blk.envelope}) <> BF.encode(:batch_done)
    :ok = Frame.send_msg(peer_end, @block_fetch, packed)

    assert :ok = Task.await(task, 2_000)
    assert [raw] = collect_sunk()
    assert raw == blk.raw
  end
end
