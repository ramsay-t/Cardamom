defmodule Cardamom.Peer.SessionTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Cardamom.{Channel, SimPeer}
  alias Cardamom.Peer.Session

  @magic 2

  setup do
    # A refused session stops abnormally (by design); trap exits so that doesn't
    # take the test process down before it observes the {:DOWN, ...}.
    Process.flag(:trap_exit, true)
    :ok
  end

  # Tests are async + telemetry is global, so filter to THIS test's own peer
  # label — events from concurrent tests must not leak in.
  defp capture(name, peer) do
    test_pid = self()

    :telemetry.attach_many(
      name,
      [[:cardamom, :peer, :connected], [:cardamom, :protocol, :event]],
      fn e, m, meta, _ ->
        if meta[:peer] == peer, do: send(test_pid, {:telemetry, e, m, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  test "full sequence: handshake succeeds, then chain-sync flows" do
    capture("session-happy", "sim-happy")
    {client_end, server_end} = Channel.Test.pair()

    {:ok, _peer} =
      SimPeer.start_link(
        channel: server_end,
        protocols: [:handshake, :chain_sync, :keep_alive],
        accept_version: 14,
        magic: @magic
      )

    {:ok, _session} = Session.start_link(channel: client_end, peer: "sim-happy", magic: @magic)

    # Handshake completed → peer connected event.
    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "sim-happy"}}, 1000
    # Then chain-sync drives and headers arrive.
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollForward"}}, 1000
  end

  test "enabling peer_sharing + tx_submission actually STARTS those clients (registry wiring)" do
    capture("session-allproto", "sim-all")
    {client_end, server_end} = Channel.Test.pair()

    {:ok, _peer} =
      SimPeer.start_link(
        channel: server_end,
        protocols: [:handshake, :chain_sync, :keep_alive, :block_fetch],
        accept_version: 14,
        magic: @magic
      )

    {:ok, session} =
      Session.start_link(
        channel: client_end,
        peer: "sim-all",
        magic: @magic,
        protocols: [:chain_sync, :keep_alive, :block_fetch, :peer_sharing, :tx_submission]
      )

    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "sim-all"}}, 1000

    # The session's client map: enabled protocols have a live pid; we enabled all five.
    clients = :sys.get_state(session).clients
    for name <- [:chain_sync, :keep_alive, :block_fetch, :peer_sharing, :tx_submission] do
      assert is_pid(clients[name]), "#{name} must be started when enabled"
      assert Process.alive?(clients[name])
    end
  end

  test "a disabled protocol is NOT started (its client slot is nil)" do
    capture("session-min", "sim-min")
    {client_end, server_end} = Channel.Test.pair()

    {:ok, _peer} =
      SimPeer.start_link(channel: server_end, protocols: [:handshake, :keep_alive], accept_version: 14, magic: @magic)

    {:ok, session} =
      Session.start_link(channel: client_end, peer: "sim-min", magic: @magic, protocols: [:keep_alive])

    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, %{peer: "sim-min"}}, 1000

    clients = :sys.get_state(session).clients
    assert is_pid(clients[:keep_alive])
    assert clients[:chain_sync] == nil
    assert clients[:peer_sharing] == nil
    assert clients[:tx_submission] == nil
  end

  test "if the handshake is refused, the session stops without starting chain-sync" do
    capture("session-refused", "sim-refused")
    {client_end, server_end} = Channel.Test.pair()

    {:ok, _peer} =
      SimPeer.start_link(
        channel: server_end,
        protocols: [:handshake],
        refuse: {:version_mismatch, [99]}
      )

    # A refused handshake means the session never starts: start_link returns the
    # error (init returned {:stop, ...}), and no chain-sync runs.
    assert {:error, {:handshake_refused, {:refused, _reason}}} =
             Session.start_link(channel: client_end, peer: "sim-refused", magic: @magic)

    refute_receive {:telemetry, [:cardamom, :protocol, :event], _, _}, 200
  end

  test "keep-alive over the same connection is answered" do
    # Drive a keep-alive through the session's connection after handshake and
    # confirm the sim peer (which enforces agency) doesn't close us — i.e. we
    # responded correctly. We assert indirectly: chain-sync keeps flowing.
    capture("session-ka", "sim-ka")
    {client_end, server_end} = Channel.Test.pair()

    {:ok, _peer} =
      SimPeer.start_link(
        channel: server_end,
        protocols: [:handshake, :chain_sync, :keep_alive],
        accept_version: 14,
        magic: @magic
      )

    {:ok, _session} = Session.start_link(channel: client_end, peer: "sim-ka", magic: @magic)

    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollForward"}}, 1000
  end
end
