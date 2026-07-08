defmodule Cardamom.ChainSync.ForestBackpressureTest do
  @moduledoc """
  SPEC (deliberate design intent): the chain-sync pull loop RENDEZVOUSES with the
  forest before pulling again. "Stop pulling until we've handled the last one" —
  the client must NOT send the next `MsgRequestNext` until the forest has applied
  the current header.

  This is the backpressure that bounds the Forest.Server mailbox under fan-out:
  each peer's pull loop self-throttles to the forest's throughput, so the number
  of in-flight forest writes is bounded by the peer count, not by chain length. A
  wedged/slow forest correctly stalls ingest rather than letting the request loop
  race unboundedly ahead (which a fire-and-forget `cast` would allow).

  Mechanism: we register a STUB process under the `Cardamom.Forest.Server` name
  that parks on the add (acknowledges receipt to the test, then withholds any
  reply). The chain-sync client feeds the forest BEFORE issuing the next
  RequestNext (see ChainSync.Client.handle_msg/2: header_meta → feed_forest, then
  request_next). So:

    * if the forest call is SYNCHRONOUS, the client blocks on it and emits NO
      RequestNext while the forest is parked — then emits exactly one once released;
    * if it is a fire-and-forget cast, the client races ahead and RequestNext
      appears immediately (this is what we are ruling out — the test goes red).
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Cardamom.{Channel, ChainSync, Connection, Mux.Frame}
  alias Cardamom.Protocol.ChainSync.Codec, as: CS
  alias Cardamom.Ledger.Conway.HeaderBuilder

  @chain_sync 2

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # A stand-in for Forest.Server, registered under its real name, that PARKS on the
  # add: it tells the test it received the add, then blocks (no reply) until the
  # test sends {:release, ref}. It speaks the GenServer.call protocol so it works
  # whether add_header is a cast OR a call — a cast it simply receives and parks on;
  # a call it receives, parks on, and only then replies. Either way it lets us probe
  # whether the client raced ahead while the forest was busy.
  defp start_parking_forest(test_pid) do
    pid =
      spawn_link(fn ->
        # GenServer.call sends {:"$gen_call", {from_pid, tag}, request}; cast sends
        # {:"$gen_cast", request}. Match both so we don't depend on which one the
        # client uses — the whole point is to detect the difference behaviourally.
        receive do
          {:"$gen_call", from, {:add, _hash, _parent} = req} ->
            send(test_pid, {:forest_got, req})
            # PARK: hold the caller until released, THEN reply (synchronous rendezvous).
            receive do
              :release -> GenServer.reply(from, :ok)
            end

          {:"$gen_cast", {:add, _hash, _parent} = req} ->
            send(test_pid, {:forest_got, req})
            # PARK without replying — nobody is waiting on a cast, which is exactly
            # the racy behaviour we want the test to catch.
            receive do
              :release -> :ok
            end
        end
      end)

    # The application supervisor runs the real Forest.Server under this name. Steal
    # the name for the duration of the test, then restore it so we don't disturb the
    # shared singleton other (async: false) tests rely on.
    real = Process.whereis(Cardamom.Forest.Server)
    if real, do: Process.unregister(Cardamom.Forest.Server)
    Process.register(pid, Cardamom.Forest.Server)

    on_exit(fn ->
      if Process.whereis(Cardamom.Forest.Server) == pid,
        do: Process.unregister(Cardamom.Forest.Server)

      if Process.alive?(pid), do: Process.exit(pid, :kill)
      if real && Process.alive?(real), do: Process.register(real, Cardamom.Forest.Server)
    end)

    pid
  end

  # depth: 1 so the quota is a single slot — proves "don't request the next until this one is done".
  defp start_stack do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "bp")
    {:ok, cs} = ChainSync.Client.start_link(conn: conn, peer: "bp", resume: false, pipeline_depth: 1)
    # Drain the initial RequestNext the client sends on start (StIdle agency).
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    {conn, cs, peer_end}
  end

  defp roll_forward(pe, hdr) do
    tip = [[hdr.slot, %CBOR.Tag{tag: :bytes, value: hdr.hash}], hdr.block_number]
    :ok = Frame.send_msg(pe, @chain_sync, CS.encode({:roll_forward, hdr.envelope, tip}))
  end

  # BACKPRESSURE BY HANDLER COMPLETION (Ramsay's model): a RollForward spawns a HeaderHandler that
  # holds the in-flight SLOT until it COMPLETES; chain-sync must NOT request the next header while
  # the (depth=1) slot is occupied by an incomplete handler. We stall the handler by parking the
  # forest inside its add_header call, then prove: no next request while parked; exactly one after
  # the handler is released and completes (its :DOWN frees the slot and refills by one).
  test "the client does NOT request the next header until the current handler completes" do
    forest = start_parking_forest(self())
    {_conn, cs, pe} = start_stack()

    hdr = HeaderBuilder.build(block_number: 1, slot: 100)
    roll_forward(pe, hdr)

    # The handler ran decode → validate → and is now PARKED feeding the forest (proving the header
    # passed the validation gate and its handler is live but incomplete — holding the slot).
    assert_receive {:forest_got, {:add, _hash, _parent}}, 1_000

    # CORE ASSERTION: the single slot is held by the incomplete handler → NO next request goes out.
    assert {:error, :timeout} = Frame.recv_msg(pe, <<>>, 300),
           "client requested the next header while the current handler was still incomplete " <>
             "(backpressure by handler-completion is not enforced)"

    assert Process.alive?(cs), "client is alive, just not requesting (main loop not frozen)"

    # Release the forest → handler completes → its :DOWN frees the slot → chain-sync requests one more.
    send(forest, :release)

    assert {:ok, payload, _, _} = Frame.recv_msg(pe, <<>>, 5_000)
    assert {:ok, :request_next, ""} = CS.decode(payload),
           "after the handler completed, the client requests exactly the next header"
  end
end
