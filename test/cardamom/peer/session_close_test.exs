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
            protocols: [:handshake, :chain_sync, :keep_alive],
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
end
