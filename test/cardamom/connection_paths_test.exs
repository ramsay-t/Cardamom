defmodule Cardamom.ConnectionPathsTest do
  @moduledoc """
  The bearer's error and shutdown paths — the code that runs when things are already
  going wrong, most often left untested. Worth chasing precisely because a bug here
  bites on the real network and is hard to reproduce.

  (Keep-alive malformed/echo paths moved to KeepAlive.ClientTest with the protocol
  split; chain-sync paths to ChainSync.ClientTest.)
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Cardamom.{Channel, Connection, Mux.Frame}

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp capture(name) do
    test_pid = self()

    :telemetry.attach_many(
      name,
      [[:cardamom, :peer, :connected], [:cardamom, :peer, :disconnected], [:cardamom, :protocol, :event]],
      fn e, m, meta, _ -> send(test_pid, {:telemetry, e, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  test "the bearer OUTLIVES a linked protocol exiting cleanly (does not mirror it)" do
    # The bearer must not die when one mini-protocol stops — else its teardown would
    # close the socket out from under another protocol's polite MsgDone. It survives
    # and keeps serving; it dies only when its CHANNEL closes or its supervisor stops it.
    {client_end, _peer_end} = Channel.Test.pair()
    proto = spawn(fn -> receive do: (:go -> :ok) end)
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "linked")
    ref = Process.monitor(conn)

    send(conn, {:EXIT, proto, :shutdown})

    refute_receive {:DOWN, ^ref, :process, ^conn, _}, 300
    assert Process.alive?(conn)
  end

  test "the bearer OUTLIVES a linked protocol crashing (logs, keeps serving)" do
    {client_end, _peer_end} = Channel.Test.pair()
    proto = spawn(fn -> receive do: (:go -> :ok) end)
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "linked-crash")
    ref = Process.monitor(conn)

    # A (simulated) protocol process crash signal — NOT self(), which is genuinely
    # linked to conn and would really kill it.
    send(conn, {:EXIT, proto, {:badmatch, 7}})

    refute_receive {:DOWN, ^ref, :process, ^conn, _}, 300
    assert Process.alive?(conn)
  end

  test "a non-:closed channel error still disconnects cleanly (telemetry + normal stop)" do
    defmodule FlakyChannel do
      @behaviour Cardamom.Channel
      def send(_, _), do: :ok
      def recv(_, _), do: {:error, :econnreset}
      def close(_), do: :ok
    end

    capture("conn-flaky")
    {:ok, conn} = Connection.start_link(channel: {FlakyChannel, :ref}, peer: "flaky")
    ref = Process.monitor(conn)

    assert_receive {:telemetry, [:cardamom, :peer, :disconnected], _, %{peer: "flaky"}}, 1000
    assert_receive {:DOWN, ^ref, :process, ^conn, :normal}, 1000
  end

  test "an SDU for an unknown mini-protocol number is dropped (not a crash)" do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "unknown-proto")

    # protocol 99 has no registered handler — the bearer drops it.
    :ok = Frame.send_msg(peer_end, 99, <<1, 2, 3>>)
    Process.sleep(100)
    assert Process.alive?(conn)
  end
end
