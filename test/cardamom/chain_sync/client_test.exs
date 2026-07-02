defmodule Cardamom.ChainSync.ClientTest do
  @moduledoc """
  Chain-sync CLIENT behaviour (was tested via Connection before the bearer/protocol
  split). The client holds agency at StIdle: it sends RequestNext, reacts to
  RollForward/RollBackward/AwaitReply, emits telemetry, and asks again. We drive it
  with a bearer (Connection) over a Channel.Test pair and script the peer end.
  """
  use ExUnit.Case, async: false

  alias Cardamom.{Channel, Connection, Mux.Frame}
  alias Cardamom.ChainSync
  alias Cardamom.Protocol.ChainSync.Codec, as: CSCodec

  @chain_sync 2

  setup do
    # We start/stop the bearer + client; trap exits so a child's exit signal during
    # teardown doesn't take the test process down.
    Process.flag(:trap_exit, true)

    :ok
  end

  defp capture_events(name) do
    test_pid = self()

    :telemetry.attach_many(
      name,
      [
        [:cardamom, :peer, :connected],
        [:cardamom, :peer, :disconnected],
        [:cardamom, :protocol, :event]
      ],
      fn event, meas, meta, _ -> send(test_pid, {:telemetry, event, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  # Start a bearer + a chain-sync client over the client end of a fresh pair.
  # Returns {conn, chain_sync, peer_end}. start_supervised! tears them (and their
  # reader process) down cleanly before the next test — good hygiene so no stack
  # lingers between tests.
  # Default pipeline_depth: 1 keeps these behaviour tests in strict single-in-flight mode
  # (request→reply→request), so "asks again" means exactly one re-request. The pipelining
  # test overrides depth explicitly.
  defp start_stack(peer_label \\ "scripted", depth \\ 1) do
    {client_end, peer_end} = Channel.Test.pair()

    conn =
      start_supervised!(
        {Connection, [channel: client_end, peer: peer_label]},
        id: :bearer
      )

    cs =
      start_supervised!(
        {ChainSync.Client, [conn: conn, peer: peer_label, resume: false, pipeline_depth: depth]},
        id: :chain_sync
      )

    {conn, cs, peer_end}
  end

  # Drain exactly one RequestNext (StIdle demand) off the peer end, asserting it decodes. Threads
  # the leftover buffer: send_frame may coalesce several SDUs into one channel read, so recv_msg's
  # `rest` must be carried into the next call or trailing frames are silently dropped.
  defp assert_request_next(peer_end, buf \\ <<>>) do
    assert {:ok, payload, _, rest} = Frame.recv_msg(peer_end, buf, 1_000)
    assert {:ok, :request_next, ""} = CSCodec.decode(payload)
    rest
  end

  test "sends an initial RequestNext on start (client holds StIdle agency)" do
    capture_events("cs-connect")
    {_conn, _cs, peer_end} = start_stack()

    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}

    assert {:ok, payload, _sdu, _rest} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert {:ok, :request_next, ""} = CSCodec.decode(payload)
  end

  test "parses a RollForward and emits a protocol event, then asks again" do
    capture_events("cs-rollfwd")
    {_conn, _cs, peer_end} = start_stack()
    # Sync barrier: confirm the handler is live and the stack is up before sending.
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}, 1_000
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    header = :crypto.strong_rand_bytes(16)
    msg = {:roll_forward, header, [123, <<0::256>>]}
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode(msg))

    assert_receive {:telemetry, [:cardamom, :protocol, :event], %{count: 1},
                    %{msg: "RollForward", header_bytes: 16, tip: %{slot: 123}}}, 1_000

    assert {:ok, payload, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert {:ok, :request_next, ""} = CSCodec.decode(payload)
  end

  test "parses a RollBackward and emits a protocol event" do
    capture_events("cs-rollback")
    {_conn, _cs, peer_end} = start_stack()
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}, 1_000
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    msg = {:roll_backward, [50, <<1::256>>], [123, <<2::256>>]}
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode(msg))

    assert_receive {:telemetry, [:cardamom, :protocol, :event], _,
                    %{msg: "RollBackward", point: %{slot: 50}}}, 1_000
  end

  test "the FIRST RollBackward is the cursor-set (NOT a reorg wipe); a later one IS a reorg" do
    # REGRESSION: on resume/cold-start the producer's first RollBackward establishes the read
    # cursor at the intersection — it must NOT trigger a UTxO rollback (that deleted all state
    # above the intersection: the 136k-block wipe). The event tags the first one cursor_set:true.
    capture_events("cs-cursorset")
    {_conn, _cs, peer_end} = start_stack()
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}, 1_000
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    # 1st RollBackward → cursor-set (no reorg).
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:roll_backward, [50, <<1::256>>], [123, <<2::256>>]}))
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _,
                    %{msg: "RollBackward", cursor_set: true}}, 1_000
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    # A RollForward advances us into streaming.
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:roll_forward, :crypto.strong_rand_bytes(16), [124, <<0::256>>]}))
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollForward"}}, 1_000
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    # 2nd RollBackward → a genuine reorg (NOT tagged cursor_set).
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:roll_backward, [60, <<3::256>>], [124, <<4::256>>]}))
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollBackward"} = m}, 1_000
    refute Map.get(m, :cursor_set), "a mid-stream RollBackward is a real reorg, not a cursor-set"
  end

  test "handles AwaitReply without crashing or re-requesting" do
    capture_events("cs-await")
    {_conn, cs, peer_end} = start_stack()
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}, 1_000
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode(:await_reply))

    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "AwaitReply"}}, 1_000
    assert Process.alive?(cs)
  end

  # THE 1962 MUX INVARIANT for chain-sync (the same class as the block-fetch block-split
  # bug, 2026-06-22): a ~1KB header in a RollForward can be split across SDU boundaries.
  # The client must carry the partial tail and reassemble it, not lose sync.
  test "a RollForward SPLIT across two SDUs is reassembled, not dropped" do
    capture_events("cs-split")
    {_conn, cs, peer_end} = start_stack()
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}, 1_000
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    # A big opaque header so the message is well over a trivial size; encode the whole
    # RollForward, then cut its bytes in half across two SDU deliveries.
    header = :crypto.strong_rand_bytes(1200)
    msg_bytes = CSCodec.encode({:roll_forward, header, [123, <<0::256>>]})
    cut = div(byte_size(msg_bytes), 2)
    <<head::binary-size(cut), tail::binary>> = msg_bytes

    :ok = Frame.send_msg(peer_end, @chain_sync, head)
    :ok = Frame.send_msg(peer_end, @chain_sync, tail)

    # The reassembled RollForward must produce exactly one protocol event (and the
    # client must then ask for the next — proving it processed the whole message).
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollForward", header_bytes: 1200}}, 1_000
    assert {:ok, payload, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert {:ok, :request_next, ""} = CSCodec.decode(payload)
    assert Process.alive?(cs)
  end

  test "tolerates an undecodable chain-sync payload without crashing" do
    capture_events("cs-baddecode")
    {_conn, cs, peer_end} = start_stack()
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}, 1_000
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    :ok = Frame.send_msg(peer_end, @chain_sync, <<0xFF, 0xFF, 0xFF>>)
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:roll_forward, <<0>>, [9, <<0::256>>]}))

    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollForward"}}, 1_000
    assert Process.alive?(cs)
  end

  # PIPELINING: chain-sync is a single ORDERED channel — replies come back in chain order, so we
  # can keep N MsgRequestNext in flight to hide the per-header round-trip (the RTT-bound ~4/s was
  # the cost of strict request→reply→request). depth N ⇒ up to N outstanding requests. We do NOT
  # pipeline during the resume/intersect phase (single-in-flight until the cursor is set); the
  # pipeline fills to N on the cursor-set RollBackward, then tops back up to N after each reply.
  test "with pipeline_depth N, fills the pipeline to N in-flight requests once streaming" do
    depth = 5
    capture_events("cs-pipeline")
    # Cold start (resume: false) fires ONE initial request; pipelining begins at the cursor-set.
    {_conn, cs, peer_end} = start_stack("scripted", depth)
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}, 1_000

    # The single cold-start RequestNext.
    buf = assert_request_next(peer_end)

    # The cursor-set RollBackward (first after cold start): consumes that one in-flight request,
    # then fills the pipeline to `depth`. So the peer now sees exactly `depth` RequestNexts.
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:roll_backward, [50, <<1::256>>], [123, <<2::256>>]}))
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollBackward", cursor_set: true}}, 1_000

    buf = Enum.reduce(1..depth, buf, fn _, b -> assert_request_next(peer_end, b) end)

    # Now at N in-flight. One RollForward reply consumes one and tops back up by exactly one — the
    # pipeline stays saturated at N (steady state), not growing unboundedly.
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:roll_forward, :crypto.strong_rand_bytes(16), [124, <<0::256>>]}))
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollForward"}}, 1_000
    buf = assert_request_next(peer_end, buf)

    # And no SECOND request from that single reply (top-up is one-for-one). A stray extra request
    # would show up here; assert the channel has nothing more queued right now.
    assert {:error, :timeout} = Frame.recv_msg(peer_end, buf, 200)
    assert Process.alive?(cs)
  end

  # At the TIP the server answers a pipelined request with AwaitReply (no block yet). We must
  # consume it but NOT top up — otherwise we'd spam requests into the tip. The pipeline drains and
  # we sit waiting; the next real RollForward (a freshly minted block) refills it.
  test "AwaitReply drains an in-flight request WITHOUT re-requesting (no tip spam)" do
    depth = 3
    capture_events("cs-await-drain")
    {_conn, cs, peer_end} = start_stack("scripted", depth)
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}, 1_000
    buf = assert_request_next(peer_end)

    # Reach streaming + fill to depth.
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:roll_backward, [50, <<1::256>>], [123, <<2::256>>]}))
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollBackward", cursor_set: true}}, 1_000
    buf = Enum.reduce(1..depth, buf, fn _, b -> assert_request_next(peer_end, b) end)

    # AwaitReply consumes one in-flight request and must NOT trigger a new one.
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode(:await_reply))
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "AwaitReply"}}, 1_000
    assert {:error, :timeout} = Frame.recv_msg(peer_end, buf, 200), "AwaitReply must not re-request (tip spam)"
    assert Process.alive?(cs)
  end
end
