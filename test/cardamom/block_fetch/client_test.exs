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

  # THE 1962 MUX INVARIANT (the live bug Marcin diagnosed from the wire, 2026-06-22:
  # "the client sees something wrong with the data and drops the ball"). A single
  # block-fetch message (a ~1KB block) may be SPLIT across SDU boundaries. The client
  # must hold the partial tail and concatenate the next SDU — NOT treat the truncated
  # half as a frame error and lose sync for the rest of the stream.
  test "a block SPLIT across two SDUs is reassembled, not dropped" do
    {bf, peer_end} = scripted()
    me = self()
    blk = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 1)

    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [10, blk.header_hash], [10, blk.header_hash], collecting_sink(me)) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    # StartBatch in its own SDU, then the block's CBOR cut in half across two SDUs,
    # then BatchDone. The two halves arrive as two separate {:sdu, 3, _} deliveries.
    block_bytes = BF.encode({:block, blk.envelope})
    cut = div(byte_size(block_bytes), 2)
    <<head::binary-size(cut), tail::binary>> = block_bytes

    :ok = Frame.send_msg(peer_end, @block_fetch, BF.encode(:start_batch))
    :ok = Frame.send_msg(peer_end, @block_fetch, head)
    :ok = Frame.send_msg(peer_end, @block_fetch, tail)
    :ok = Frame.send_msg(peer_end, @block_fetch, BF.encode(:batch_done))

    assert :ok = Task.await(task, 2_000)
    assert [raw] = collect_sunk(), "the split block must reassemble into exactly one block"
    assert raw == blk.raw
  end

  # GRACEFUL CLOSE (Marcin, 2026-06-22: a RST on the wire reads as "the client choked",
  # and network engineers blame the client, not the protocol). Block-fetch holds agency
  # at StIdle; the polite exit is MsgClientDone ([1]) → StDone, mirroring chain-sync's
  # MsgDone. Without it, proto 3 is left dangling at the protocol level even on a clean
  # run. Pin that a clean shutdown puts MsgClientDone on the wire.
  test "sends MsgClientDone on a clean shutdown (graceful StDone)" do
    # The bearer + client are linked to us (scripted/start_link); trap exits so the
    # client's :shutdown stop doesn't take the test process down with it.
    Process.flag(:trap_exit, true)
    {bf, peer_end} = scripted()
    # Let the client register and settle (no in-flight request).
    Process.sleep(50)

    :ok = GenServer.stop(bf, :shutdown, 1_000)

    assert {:ok, payload, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert {:ok, :client_done, ""} = BF.decode(payload),
           "a clean shutdown must send MsgClientDone so the relay sees StDone, not a dangling proto"
  end

  test "after a split block, a SUBSEQUENT whole block still decodes (sync not lost)" do
    {bf, peer_end} = scripted()
    me = self()
    b1 = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 1)
    b2 = BlockBuilder.build(block_number: 2, slot: 20, tx_count: 2)

    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [10, b1.header_hash], [20, b2.header_hash], collecting_sink(me)) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    b1_bytes = BF.encode({:block, b1.envelope})
    cut = div(byte_size(b1_bytes), 3)
    <<head::binary-size(cut), tail::binary>> = b1_bytes

    :ok = Frame.send_msg(peer_end, @block_fetch, BF.encode(:start_batch))
    :ok = Frame.send_msg(peer_end, @block_fetch, head)
    # The tail of b1 glued to the WHOLE of b2 in one SDU — must carry over AND drain.
    :ok = Frame.send_msg(peer_end, @block_fetch, tail <> BF.encode({:block, b2.envelope}))
    :ok = Frame.send_msg(peer_end, @block_fetch, BF.encode(:batch_done))

    assert :ok = Task.await(task, 2_000)
    assert [r1, r2] = collect_sunk(), "both blocks must arrive — sync survives the boundary"
    assert r1 == b1.raw
    assert r2 == b2.raw
  end
end
