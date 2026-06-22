defmodule Cardamom.Integration.CleanShutdownTest do
  @moduledoc """
  SimPeer is the JUDGE: over a real localhost socket, it reports whether the
  client closed politely ({:sim_peer_close, :clean} = saw a chain-sync MsgDone) or
  just vanished ({:sim_peer_close, :dirty}). We command shutdowns in various ways
  and assert the verdict matches the OTP-native intent:

    * commanded clean shutdown (GenServer.stop :shutdown) -> :clean
    * abnormal kill (Process.exit :kill / a crash)        -> :dirty

  This proves, from the PEER's perspective, that clean death paths produce a
  polite goodbye and dirty ones don't — the thing that keeps Preview from seeing
  us as a misbehaving peer.
  """
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :capture_log

  alias Cardamom.{Channel, SimPeer}
  alias Cardamom.Peer.Session

  @magic 2

  # localhost listener -> SimPeer on the accepted socket, reporting close verdicts
  # to the test process.
  defp start_sim_listener do
    test_pid = self()
    {:ok, lsock, port} = Channel.Tcp.listen(0)

    {:ok, acceptor} =
      Task.start_link(fn ->
        {:ok, server_chan} = Channel.Tcp.accept(lsock, 5_000)

        {:ok, _peer} =
          SimPeer.start_link(
            channel: server_chan,
            protocols: [:handshake, :chain_sync, :keep_alive],
            accept_version: 14,
            magic: @magic,
            report_to: test_pid
          )

        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
      :gen_tcp.close(lsock)
    end)

    port
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "commanded clean shutdown is judged CLEAN by the peer (MsgDone seen)" do
    port = start_sim_listener()
    {:ok, chan} = Channel.Tcp.connect("localhost", port, 2_000)
    {:ok, session} = Session.start_link(channel: chan, peer: "clean", magic: @magic)

    # Let the connection get going (the Session started a Connection).
    Process.sleep(200)

    # Commanded clean stop of the session subtree → Connection.terminate/2 sends
    # MsgDone over the real socket.
    GenServer.stop(session, :shutdown)

    assert_receive {:sim_peer_close, :clean}, 3_000
  end

  test "an abnormal kill is judged DIRTY by the peer (no MsgDone)" do
    port = start_sim_listener()
    {:ok, chan} = Channel.Tcp.connect("localhost", port, 2_000)
    {:ok, session} = Session.start_link(channel: chan, peer: "dirty", magic: @magic)
    Process.sleep(200)

    # Brutal kill: terminate/2 does not run → no MsgDone → peer sees a dirty drop.
    Process.exit(session, :kill)

    assert_receive {:sim_peer_close, :dirty}, 3_000
  end
end
