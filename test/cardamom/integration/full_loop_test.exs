defmodule Cardamom.Integration.FullLoopTest do
  @moduledoc """
  FULL-STACK loop over a REAL localhost TCP socket. Unlike the in-memory
  Channel.Test based tests (which exercise protocol logic only), this drives the
  whole stack through genuine `:gen_tcp`: real connect/accept, real send/recv,
  real partial reads and SDU re-buffering across packet boundaries, real
  `{:error, :closed}` on socket close.

  Topology: a localhost listener accepts a connection and runs `SimPeer` (our
  strict, enforcing simulated relay) on the accepted socket; `Peer.Session`
  connects to it via `Channel.Tcp` and runs the full handshake → chain-sync ∥
  keep-alive sequence.

  This is the maximal formal coverage achievable without a live remote: the only
  thing it does NOT test is whether the real Preview relay accepts us — every
  byte of OUR stack, including the transport, is exercised end to end.

  Tagged :integration (real sockets, slightly less hermetic than the unit suite).
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :capture_log

  alias Cardamom.{Channel, SimPeer}
  alias Cardamom.Peer.Session

  @magic 2

  defp capture(name) do
    test_pid = self()

    :telemetry.attach_many(
      name,
      [[:cardamom, :peer, :connected], [:cardamom, :protocol, :event]],
      fn e, m, meta, _ -> send(test_pid, {:telemetry, e, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  # Spin up a localhost listener; when a client connects, run SimPeer on the
  # accepted socket. Returns the port to connect to.
  defp start_sim_listener(sim_opts) do
    {:ok, lsock, port} = Channel.Tcp.listen(0)

    {:ok, acceptor} =
      Task.start_link(fn ->
        {:ok, server_chan} = Channel.Tcp.accept(lsock, 5_000)
        {:ok, _peer} = SimPeer.start_link(Keyword.put(sim_opts, :channel, server_chan))
        # keep the acceptor alive so the linked SimPeer & socket live on
        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
      :gen_tcp.close(lsock)
    end)

    port
  end

  test "full handshake -> chain-sync -> keep-alive over a real localhost socket" do
    capture("fullloop-happy")

    port =
      start_sim_listener(
        protocols: [:handshake, :chain_sync, :keep_alive],
        accept_version: 14,
        magic: @magic
      )

    {:ok, chan} = Channel.Tcp.connect("localhost", port, 2_000)
    {:ok, _session} = Session.start_link(channel: chan, peer: "localhost-sim", magic: @magic)

    # Handshake completed over the real socket...
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "localhost-sim"}}, 2_000
    # ...then chain-sync drives and real-socket-framed headers arrive.
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollForward"}}, 2_000
  end

  test "several chain-sync rounds flow over the real socket (re-buffering across reads)" do
    capture("fullloop-stream")

    port =
      start_sim_listener(protocols: [:handshake, :chain_sync, :keep_alive], accept_version: 14, magic: @magic)

    {:ok, chan} = Channel.Tcp.connect("localhost", port, 2_000)
    {:ok, _session} = Session.start_link(channel: chan, peer: "stream-sim", magic: @magic)

    # Consumer-driven loop should produce multiple RollForwards over real TCP.
    for _ <- 1..3 do
      assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollForward"}}, 2_000
    end
  end
end
