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

  # ── MC/DC-style coverage (per Ramsay's pattern-matching paper) ────────────────────
  # Each clause of a multi-clause head is a branch of a DECISION that must be selected
  # independently; each guard is a CONDITION that must be shown both true (matches) and
  # false (falls through). Line coverage misses the clause never taken — the "lines that
  # aren't there but should be". The cases below drive the unselected clauses.

  describe "unwrap/1 — every clause selected independently (the block-envelope decision)" do
    # Clause 1 (tag 24) is covered by the happy-path tests. Here: the other three.
    setup do
      {bf, peer_end} = scripted()
      me = self()
      task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [1, <<1>>], [9, <<9>>], collecting_sink(me)) end)
      {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
      %{peer_end: peer_end, task: task, me: me}
    end

    test "clause 2: a bare tag(:bytes) block (no wrapCBORinCBOR) still unwraps", %{peer_end: pe, task: task} do
      send_bf(pe, :start_batch)
      # {:block, %CBOR.Tag{tag: :bytes, value: raw}} — the second unwrap clause.
      send_bf(pe, {:block, %CBOR.Tag{tag: :bytes, value: <<7, 8, 9>>}})
      send_bf(pe, :batch_done)

      assert :ok = Task.await(task, 2_000)
      assert [<<7, 8, 9>>] = collect_sunk()
    end

    test "clause 3: a raw-binary block payload unwraps", %{peer_end: pe, task: task} do
      send_bf(pe, :start_batch)
      send_bf(pe, {:block, <<10, 11, 12>>})
      send_bf(pe, :batch_done)

      assert :ok = Task.await(task, 2_000)
      assert [<<10, 11, 12>>] = collect_sunk()
    end

    test "clause 4 (:error): a non-bytes block envelope is skipped, not stored, not crashed",
         %{peer_end: pe, task: task} do
      send_bf(pe, :start_batch)
      # A block whose payload is neither a tag-24 nor bytes nor a binary → unwrap/1 :error
      # → on_msg's :error arm ('undecodable block envelope; skipping'). in_flight is NOT
      # incremented, so BatchDone completes immediately.
      send_bf(pe, {:block, [:not, "a", "block"]})
      send_bf(pe, :batch_done)

      assert :ok = Task.await(task, 2_000)
      assert [] = collect_sunk(), "an undecodable envelope must be skipped, not sunk"
    end
  end

  test "a late handler_done with no in-flight request is ignored (race guard)" do
    {bf, _peer_end} = scripted()
    # No request in flight (req == nil). A stray {:handler_done} — e.g. a handler that
    # finished after the request already completed — hits the second clause and is a
    # no-op, not a crash.
    send(bf, {:handler_done, make_ref()})
    Process.sleep(30)
    assert Process.alive?(bf)
  end

  test "on_msg catch-all: a server message with no in-flight request is ignored" do
    {bf, peer_end} = scripted()
    # No fetch_range in flight (req == nil). A stray BatchDone must be ignored, not crash.
    send_bf(peer_end, :batch_done)
    Process.sleep(50)
    assert Process.alive?(bf), "a server message with no request must be a no-op"
  end

  # A client with a SHORT configurable idle timeout (the :idle_timeout_ms seam), so the
  # stall path runs in test time, not 90s.
  defp scripted_idle(ms) do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "bf")
    {:ok, bf} = BlockFetch.Client.start_link(conn: conn, peer: "bf", idle_timeout_ms: ms)
    {bf, peer_end}
  end

  test "a STALE idle-timeout token is a no-op (doesn't tear the request down)" do
    {bf, peer_end} = scripted_idle(10_000)
    me = self()
    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [1, <<1>>], [9, <<9>>], collecting_sink(me)) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    # A forged/stale token doesn't match the armed idle_token → second idle_timeout
    # clause → ignored. The request must still be live (not replied).
    send(bf, {:idle_timeout, make_ref()})
    Process.sleep(30)
    assert Process.alive?(bf)
    refute_received _, "a stale idle token must not complete the request"

    # Clean it up: a real BatchDone completes it.
    send_bf(peer_end, :no_blocks)
    assert :ok = Task.await(task, 2_000)
  end

  test "idle timeout WITH a handler still in flight: waits for the handler, then {:error,_}" do
    # Short idle timeout; a sink that parks until released, so a handler is genuinely
    # in flight when the idle fires — exercising the 'draining N handler(s)' branch and
    # maybe_complete WAITING for in_flight to reach 0 before replying :error.
    {bf, peer_end} = scripted_idle(80)
    me = self()
    blk = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 0)

    # The sink sends US its own pid so we can release it, then parks on :release.
    parking_sink = fn _raw ->
      send(me, {:handler_pid, self()})

      receive do
        :release -> :ok
      after
        2_000 -> :ok
      end
    end

    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [10, blk.header_hash], [10, blk.header_hash], parking_sink) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    send_bf(peer_end, :start_batch)
    send_bf(peer_end, {:block, blk.envelope})

    # Handler parked (in_flight == 1). Send NOTHING more → the 80ms idle fires while the
    # handler is still running → terminating := {:error,_} but the reply is withheld.
    assert_receive {:handler_pid, handler}, 1_000
    refute match?({:ok, _}, Task.yield(task, 200)), "must not reply while a handler is in flight"

    # Release the handler → in_flight hits 0 → maybe_complete now replies the idle error.
    send(handler, :release)
    assert {:error, :idle_timeout} = Task.await(task, 2_000)
  end

  describe "clean?/1 — terminate decision, each branch" do
    test "a {:shutdown, reason} stop is CLEAN → MsgClientDone is sent" do
      Process.flag(:trap_exit, true)
      {bf, peer_end} = scripted()
      Process.sleep(30)

      :ok = GenServer.stop(bf, {:shutdown, :done}, 1_000)

      assert {:ok, payload, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
      assert {:ok, :client_done, ""} = BF.decode(payload)
    end

    test "an ABNORMAL stop is NOT clean → NO MsgClientDone (no rude goodbye on a crash)" do
      Process.flag(:trap_exit, true)
      {bf, peer_end} = scripted()
      Process.sleep(30)

      # An abnormal exit reason → clean?/1 falls through to false → terminate sends
      # nothing. (We just drop; the peer sees a normal dropped connection.)
      Process.exit(bf, :kill)
      Process.sleep(30)

      assert {:error, :timeout} = Frame.recv_msg(peer_end, <<>>, 200),
             "an abnormal death must NOT emit MsgClientDone"
    end
  end

  test "a sink that RAISES is caught (handler crash logged), completion still proceeds" do
    {bf, peer_end} = scripted()
    blk = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 0)
    boom = fn _raw -> raise "sink boom" end

    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [10, blk.header_hash], [10, blk.header_hash], boom) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    send_bf(peer_end, :start_batch)
    send_bf(peer_end, {:block, blk.envelope})
    send_bf(peer_end, :batch_done)

    # The handler's rescue arm fires (logged), and it STILL sends {:handler_done}, so
    # the batch completes :ok rather than hanging on a crashed handler.
    assert :ok = Task.await(task, 2_000)
    assert Process.alive?(bf)
  end

  test "genuine corruption mid-stream: whole prior messages apply, the rest is dropped" do
    {bf, peer_end} = scripted()
    me = self()
    blk = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 0)

    task = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [10, blk.header_hash], [10, blk.header_hash], collecting_sink(me)) end)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    # StartBatch + a whole block, then GENUINELY malformed bytes (not a short read) in
    # the SAME SDU → reassemble's {:error, msgs, _} branch: the block applies, the
    # corruption is logged and the tail dropped. A 0xFF break alone is malformed here.
    packed = BF.encode(:start_batch) <> BF.encode({:block, blk.envelope}) <> <<0xFF>>
    :ok = Frame.send_msg(peer_end, @block_fetch, packed)
    send_bf(peer_end, :batch_done)

    assert :ok = Task.await(task, 2_000)
    assert [raw] = collect_sunk(), "the whole block before the corruption must still be sunk"
    assert raw == blk.raw
  end

  test "a second fetch_range while one is in flight is QUEUED, not rejected, and runs after" do
    # Round-robin spreads ranges across clients; a collision (coming back round to a
    # busy client) must QUEUE behind the in-flight range, not fail with :busy. One
    # channel = one StStreaming at a time, so serial-by-queue is protocol-correct.
    {bf, peer_end} = scripted()
    me = self()
    b1 = BlockBuilder.build(block_number: 1, slot: 10, tx_count: 0)
    b2 = BlockBuilder.build(block_number: 2, slot: 20, tx_count: 0)

    # Caller 1 starts a range (and holds it open — we haven't sent BatchDone yet).
    # NB: thread Frame.recv_msg's leftover buffer (4th elem) into the next call — the
    # channel may coalesce writes into one read, and a fresh <<>> would drop the rest.
    t1 = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [10, b1.header_hash], [10, b1.header_hash], collecting_sink(me)) end)
    {:ok, req1, _, buf} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert {:ok, {:request_range, _, _}, ""} = BF.decode(req1)

    # Caller 2 fires WHILE caller 1 is in flight. It must NOT get :busy — it queues.
    t2 = Task.async(fn -> BlockFetch.Client.fetch_range(bf, [20, b2.header_hash], [20, b2.header_hash], collecting_sink(me)) end)

    # The client must NOT have sent caller 2's RequestRange yet (it's queued behind #1).
    assert {:error, :timeout} = Frame.recv_msg(peer_end, buf, 200),
           "the queued request must not hit the wire until the first completes"

    # Complete caller 1's batch → it replies, then the queued caller 2 starts. The
    # dequeue→send of req2 happens in the client when caller 1's handler finishes, which
    # is concurrent with t1's reply; wait for t1, then read req2 with a generous timeout
    # (threading the leftover buffer, since the channel may coalesce reads).
    send_bf(peer_end, :start_batch)
    send_bf(peer_end, {:block, b1.envelope})
    send_bf(peer_end, :batch_done)
    assert :ok = Task.await(t1, 2_000)

    # NOW caller 2's RequestRange goes out (possibly a moment after t1's reply).
    assert {:ok, req2, _, _} = Frame.recv_msg(peer_end, buf, 2_000)
    assert {:ok, {:request_range, _, _}, ""} = BF.decode(req2)
    send_bf(peer_end, :start_batch)
    send_bf(peer_end, {:block, b2.envelope})
    send_bf(peer_end, :batch_done)
    assert :ok = Task.await(t2, 2_000)

    # Both blocks were sunk (both ranges served, in order).
    assert [r1, r2] = collect_sunk()
    assert r1 == b1.raw
    assert r2 == b2.raw
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
