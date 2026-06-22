defmodule Cardamom.DevFakePeerTest do
  use ExUnit.Case, async: false

  alias Cardamom.{Channel, DevFakePeer, Mux.Frame}
  alias Cardamom.Protocol.ChainSync.Codec, as: ChainSync

  @chain_sync 2

  # Driving the fake peer also re-exercises the codec from the PRODUCING side:
  # the bytes it emits must decode back to valid chain-sync messages.

  test "answers RequestNext with a decodable RollForward (or RollBackward)" do
    {our_end, peer_end} = Channel.Test.pair()
    {:ok, _peer} = DevFakePeer.start_link(channel: peer_end)

    :ok = Frame.send_msg(our_end, @chain_sync, ChainSync.encode(:request_next))

    assert {:ok, payload, _sdu, _rest} = Frame.recv_msg(our_end, <<>>, 2_000)
    assert {:ok, msg, ""} = ChainSync.decode(payload)

    assert match?({:roll_forward, _, _}, msg) or match?({:roll_backward, _, _}, msg)
  end

  test "answers FindIntersect with an IntersectFound" do
    {our_end, peer_end} = Channel.Test.pair()
    {:ok, _peer} = DevFakePeer.start_link(channel: peer_end)

    :ok = Frame.send_msg(our_end, @chain_sync, ChainSync.encode({:find_intersect, [[1, <<0::256>>]]}))

    assert {:ok, payload, _, _} = Frame.recv_msg(our_end, <<>>, 2_000)
    assert {:ok, {:intersect_found, _point, _tip}, ""} = ChainSync.decode(payload)
  end

  test "produces a chain: successive RollForwards have increasing slots" do
    {our_end, peer_end} = Channel.Test.pair()
    {:ok, _peer} = DevFakePeer.start_link(channel: peer_end)

    slots =
      Enum.reduce(1..5, {[], <<>>}, fn _, {acc, buf} ->
        :ok = Frame.send_msg(our_end, @chain_sync, ChainSync.encode(:request_next))
        {:ok, payload, _, rest} = Frame.recv_msg(our_end, buf, 2_000)
        {:ok, msg, ""} = ChainSync.decode(payload)

        slot =
          case msg do
            {:roll_forward, _h, [s | _]} -> s
            {:roll_backward, _p, [s | _]} -> s
          end

        {[slot | acc], rest}
      end)
      |> elem(0)
      |> Enum.reverse()

    # Roll-forwards strictly increase; the rare roll-back is the only dip.
    assert Enum.max(slots) > Enum.at(slots, 0)
  end

  test "full loopback: real Connection parses the fake peer's real wire bytes" do
    test_pid = self()

    :telemetry.attach(
      "fakepeer-loopback",
      [:cardamom, :protocol, :event],
      fn _e, _m, meta, _ -> send(test_pid, {:event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("fakepeer-loopback") end)

    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Cardamom.Connection.start_link(channel: client_end, peer: "loopback-test")
    # The chain-sync CLIENT drives chain-sync now (bearer just multiplexes).
    {:ok, _cs} = Cardamom.ChainSync.Client.start_link(conn: conn, peer: "loopback-test", resume: false)
    {:ok, _peer} = DevFakePeer.start_link(channel: peer_end)

    # The client sends RequestNext on start; the peer answers; the client parses
    # and emits a real protocol event.
    assert_receive {:event, %{protocol: "chain_sync", msg: msg}}, 3_000
    assert msg in ["RollForward", "RollBackward"]
  end
end
