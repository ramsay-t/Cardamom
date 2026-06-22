defmodule Cardamom.PeersTest do
  use ExUnit.Case, async: false

  alias Cardamom.Peers

  setup do
    # Peers is a started singleton; reset it for a clean per-test view.
    Peers.reset()
    :ok
  end

  test "registering a peer makes it appear in the list with its metadata" do
    Peers.register(self(), %{address: "1.2.3.4:3001", direction: :outbound, version: 14})

    [p] = Peers.list()
    assert p.address == "1.2.3.4:3001"
    assert p.direction == :outbound
    assert p.version == 14
    assert p.name == nil
    assert p.protocols == %{}
  end

  test "protocol activity is recorded per peer (from telemetry)" do
    Peers.register(self(), %{address: "1.2.3.4:3001", direction: :outbound, version: 14})

    :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{
      peer: "1.2.3.4:3001",
      protocol: "chain_sync",
      msg: "RollForward"
    })

    # cast is async; settle.
    _ = Peers.list()
    [p] = Peers.list()
    cs = p.protocols["chain_sync"]
    assert cs.count == 1
    assert cs.last_msg == "RollForward"
    assert is_integer(cs.last_at)
  end

  test "activity for an unknown peer is ignored (no phantom peers)" do
    :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{
      peer: "9.9.9.9:1",
      protocol: "chain_sync",
      msg: "RollForward"
    })

    _ = Peers.list()
    assert Peers.list() == []
  end

  test "a dead peer process is dropped from the list" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Peers.register(pid, %{address: "5.6.7.8:3001", direction: :outbound, version: 14})
    assert length(Peers.list()) == 1

    Process.exit(pid, :kill)
    # give the monitor message time to arrive
    _ = Peers.list()
    Process.sleep(20)
    assert Peers.list() == []
  end
end
