defmodule Cardamom.ConnectionTest do
  @moduledoc """
  The bearer/mux itself (post protocol-split): it owns the socket, ROUTES inbound
  SDUs to the process registered for each mini-protocol number, writes outbound
  frames as the single writer, and emits peer connect/disconnect telemetry. It
  holds NO protocol logic — that's tested in the per-protocol client tests.
  """
  use ExUnit.Case, async: false

  alias Cardamom.{Channel, Connection, Mux.Frame}

  @chain_sync 2
  @keep_alive 8

  defp capture_events(name) do
    test_pid = self()

    :telemetry.attach_many(
      name,
      [[:cardamom, :peer, :connected], [:cardamom, :peer, :disconnected]],
      fn event, meas, meta, _ -> send(test_pid, {:telemetry, event, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  test "emits peer.connected on start" do
    capture_events("bearer-connect")
    {client_end, _peer_end} = Channel.Test.pair()

    {:ok, _conn} = Connection.start_link(channel: client_end, peer: "scripted")

    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "scripted"}}
  end

  test "routes an inbound SDU to the registered handler process" do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "scripted")

    # Register THIS test process as the handler for chain-sync.
    :ok = Connection.register(conn, @chain_sync)

    :ok = Frame.send_msg(peer_end, @chain_sync, <<1, 2, 3>>)

    assert_receive {:sdu, @chain_sync, <<1, 2, 3>>}, 1_000
  end

  test "an SDU for an unregistered mini-protocol is dropped (not a crash)" do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "scripted")
    :ok = Connection.register(conn, @chain_sync)

    # Unknown proto: nobody registered → dropped silently.
    :ok = Frame.send_msg(peer_end, @keep_alive, <<9, 9>>)
    # A registered one still routes — proves the bearer survived the drop.
    :ok = Frame.send_msg(peer_end, @chain_sync, <<7>>)

    assert_receive {:sdu, @chain_sync, <<7>>}, 1_000
    refute_received {:sdu, @keep_alive, _}
    assert Process.alive?(conn)
  end

  test "send_frame writes a framed message to the socket (single writer)" do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "scripted")

    :ok = Connection.send_frame(conn, @chain_sync, <<0xAB, 0xCD>>)

    assert {:ok, <<0xAB, 0xCD>>, sdu, _rest} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert sdu.protocol_num == @chain_sync
  end

  test "emits peer.disconnected and stops when the channel closes" do
    capture_events("bearer-disc")
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "scripted")
    ref = Process.monitor(conn)

    Channel.close(peer_end)

    assert_receive {:telemetry, [:cardamom, :peer, :disconnected], _, %{peer: "scripted"}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^conn, :normal}, 2_000
  end
end
