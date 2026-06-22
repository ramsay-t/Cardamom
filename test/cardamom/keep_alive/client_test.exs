defmodule Cardamom.KeepAlive.ClientTest do
  @moduledoc """
  The keep-alive CLIENT driver. We hold client agency in keep-alive: the protocol's
  StClient timeout is 97s (ouroboros-network KeepAlive/Codec.hs:105), so a relay
  reaps us if we go silent. This process pings on a timer; these tests use a short
  interval (no real waiting) and assert: (a) we send MsgKeepAlive [0, cookie]
  periodically, (b) the cookie advances, (c) we echo a peer's ping, (d) the
  relay's response is accepted without sending anything back.
  """
  use ExUnit.Case, async: false

  alias Cardamom.{Channel, Connection, Mux.Frame, KeepAlive}

  @keep_alive 8

  setup do
    # We start_link the client/bearer and stop them in tests; trap exits so their
    # exit signals don't take the test process down.
    Process.flag(:trap_exit, true)
    :ok
  end

  defp start_stack(interval_ms) do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "scripted")
    {:ok, ka} = KeepAlive.Client.start_link(conn: conn, interval_ms: interval_ms)
    {conn, ka, peer_end}
  end

  defp recv_keepalive(peer_end) do
    assert {:ok, payload, sdu, _rest} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert sdu.protocol_num == @keep_alive
    assert {:ok, decoded, _} = CBOR.decode(payload)
    decoded
  end

  test "sends MsgKeepAlive [0, cookie] on the interval, advancing the cookie" do
    {_conn, _ka, peer_end} = start_stack(50)

    # First ping fires ~one interval in.
    assert [0, c0] = recv_keepalive(peer_end)
    assert is_integer(c0)

    # Subsequent pings keep coming, with an advancing cookie.
    assert [0, c1] = recv_keepalive(peer_end)
    assert c1 == c0 + 1
  end

  test "echoes a peer-initiated ping ([0, cookie] -> [1, cookie])" do
    # Long interval so OUR pings don't interleave with the echo we're checking.
    {_conn, _ka, peer_end} = start_stack(60_000)

    :ok = Frame.send_msg(peer_end, @keep_alive, CBOR.encode([0, 4242]))

    assert [1, 4242] = recv_keepalive(peer_end)
  end

  test "accepts the relay's response ([1, cookie]) without replying" do
    {_conn, ka, peer_end} = start_stack(60_000)

    :ok = Frame.send_msg(peer_end, @keep_alive, CBOR.encode([1, 7]))

    # No frame should come back in response to a [1, _] (it's an alive-confirmation).
    assert {:error, :timeout} = Frame.recv_msg(peer_end, <<>>, 300)
    assert Process.alive?(ka)
  end

  test "stops when the bearer it is linked to dies" do
    {conn, ka, _peer_end} = start_stack(60_000)
    ref = Process.monitor(ka)

    GenServer.stop(conn, :shutdown)

    assert_receive {:DOWN, ^ref, :process, ^ka, _reason}, 2_000
  end
end
