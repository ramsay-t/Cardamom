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

  defp start_stack do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "bp")
    {:ok, cs} = ChainSync.Client.start_link(conn: conn, peer: "bp", resume: false)
    # Drain the initial RequestNext the client sends on start (StIdle agency).
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    {conn, cs, peer_end}
  end

  defp roll_forward(pe, hdr) do
    tip = [[hdr.slot, %CBOR.Tag{tag: :bytes, value: hdr.hash}], hdr.block_number]
    :ok = Frame.send_msg(pe, @chain_sync, CS.encode({:roll_forward, hdr.envelope, tip}))
  end

  test "the client does NOT request the next header until the forest has applied this one" do
    forest = start_parking_forest(self())
    {_conn, cs, pe} = start_stack()

    hdr = HeaderBuilder.build(block_number: 1, slot: 100)
    roll_forward(pe, hdr)

    # The forest receives the add (proving the client got the header and fed it).
    assert_receive {:forest_got, {:add, _hash, _parent}}, 1_000

    # CORE ASSERTION: while the forest is parked (header not yet applied), the client
    # must be blocked on the rendezvous and must NOT have raced ahead to request the
    # next header. With a fire-and-forget cast it WILL have — that's the red.
    assert {:error, :timeout} = Frame.recv_msg(pe, <<>>, 300),
           "client requested the next header before the forest applied the current one " <>
             "(the pull loop raced ahead of the forest — backpressure is not enforced)"

    # The client is alive and simply waiting (not crashed).
    assert Process.alive?(cs)

    # Release the forest → the rendezvous completes → NOW the client pulls again.
    send(forest, :release)

    assert {:ok, payload, _, _} = Frame.recv_msg(pe, <<>>, 1_000)
    assert {:ok, :request_next, ""} = CS.decode(payload),
           "after the forest applied the header, the client must request exactly the next one"
  end
end
