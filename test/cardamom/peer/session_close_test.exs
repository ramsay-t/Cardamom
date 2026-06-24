defmodule Cardamom.Peer.SessionCloseTest do
  @moduledoc """
  REGRESSION: a dead socket must bring the whole session down.

  Earlier the one-shot runner would idle after the relay dropped us — the TCP
  connection died but the session process stayed alive, so the runner's
  Process.monitor never fired and it watched a corpse for the rest of the run.

  The bearer/reader split makes the close propagate: Reader sees {:error, :closed}
  -> tells the bearer -> bearer stops -> (linked) Session stops. This test pins that
  chain so it can't silently regress: close the peer end, assert the Session dies.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Cardamom.{Channel, SimPeer}
  alias Cardamom.Peer.Session

  @magic 2

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "closing the socket brings the session process down (no idling corpse)" do
    # A localhost SimPeer so the real handshake completes and a real session forms.
    {:ok, lsock, port} = Channel.Tcp.listen(0)

    {:ok, acceptor} =
      Task.start_link(fn ->
        {:ok, server_chan} = Channel.Tcp.accept(lsock, 5_000)

        {:ok, _peer} =
          SimPeer.start_link(
            channel: server_chan,
            protocols: [:handshake, :chain_sync, :keep_alive, :block_fetch],
            accept_version: 14,
            magic: @magic
          )

        Process.sleep(:infinity)
      end)

    {:ok, chan} = Channel.Tcp.connect("localhost", port, 2_000)
    {:ok, session} = Session.start_link(channel: chan, peer: "dropme", magic: @magic)
    ref = Process.monitor(session)

    # Let it get going, then simulate the relay vanishing: kill the SimPeer side so
    # the socket closes under us (the ~97s Preview drop, but instant).
    Process.sleep(200)
    Process.exit(acceptor, :kill)

    # The close must propagate Reader -> bearer -> Session. If it doesn't, the
    # session lingers and this times out — exactly the idling bug.
    assert_receive {:DOWN, ^ref, :process, ^session, _reason}, 3_000

    :gen_tcp.close(lsock)
  end

  test "a SUPERVISED session terminated by its supervisor shuts down GRACEFULLY (MsgDone)" do
    # The bug the live run exposed: a boot-dialed session wasn't under any supervisor, so
    # app-shutdown killed it abruptly (no MsgDone). Now it runs under PeerSupervisor; this
    # pins that terminating it via the supervisor fires Session.terminate → MsgDone, which
    # the SimPeer observes as a CLEAN close.
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, lsock, port} = Channel.Tcp.listen(0)
    test_pid = self()

    {:ok, _acceptor} =
      Task.start_link(fn ->
        # Trap exits so that when our client socket closes and the bearer dies, the EXIT
        # signal doesn't reap the SimPeer before it can drain the buffered MsgDone and
        # report its verdict. The SimPeer must outlive the close to judge it.
        Process.flag(:trap_exit, true)
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

    {:ok, chan} = Channel.Tcp.connect("localhost", port, 2_000)

    # Same protocol set the SimPeer speaks — a graceful close sends a goodbye on EVERY active
    # protocol, so the session must not run one (e.g. block_fetch) the peer can't parse.
    spec = %{
      id: Session,
      start:
        {Session, :start_link,
         [[channel: chan, peer: "gs", magic: @magic, protocols: [:chain_sync, :keep_alive]]]},
      restart: :transient,
      shutdown: 10_000
    }

    {:ok, session} = DynamicSupervisor.start_child(sup, spec)
    # Let the handshake complete and chain-sync settle before we stop it.
    Process.sleep(500)

    # Terminate via the supervisor — EXACTLY what OTP does to this child on app shutdown
    # (System.stop / SIGTERM / `bin/cardamom stop`): reverse-order teardown, each child given
    # its `shutdown:` window to run terminate/2. So this proves the tree shuts the session
    # down gracefully on its own — no SignalHandler / Control.shutdown needed.
    :ok = DynamicSupervisor.terminate_child(sup, session)

    # :clean means the SimPeer parsed our chain-sync MsgDone before the socket closed.
    assert_receive {:sim_peer_close, :clean}, 3_000

    :gen_tcp.close(lsock)
  end
end
