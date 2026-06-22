defmodule Cardamom.StatsTest do
  use ExUnit.Case, async: false

  # Stats is a singleton started by the app supervisor; it's already running.
  # We exercise it by emitting telemetry and reading the snapshot.

  alias Cardamom.Stats

  test "snapshot has the expected shape" do
    s = Stats.snapshot()
    assert is_integer(s.uptime_seconds)
    assert is_integer(s.peers_connected)
    assert is_integer(s.protocol_events)
    assert is_list(s.recent)
  end

  test "a protocol event increments the counter and lands newest-first in recent" do
    before = Stats.snapshot().protocol_events

    :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{msg: "TestEvent", tag: "abc"})
    # cast is async; let it settle.
    _ = Stats.snapshot()

    snap = Stats.snapshot()
    assert snap.protocol_events == before + 1
    assert hd(snap.recent).event == "cardamom.protocol.event"
    assert hd(snap.recent).metadata.tag == "abc"
  end

  test "peer connect/disconnect adjusts the connected count" do
    :telemetry.execute([:cardamom, :peer, :connected], %{}, %{peer: "p1"})
    _ = Stats.snapshot()
    up = Stats.snapshot().peers_connected
    assert up >= 1

    :telemetry.execute([:cardamom, :peer, :disconnected], %{}, %{peer: "p1"})
    _ = Stats.snapshot()
    assert Stats.snapshot().peers_connected == up - 1
  end

  test "recent is capped (does not grow unbounded)" do
    for n <- 1..80 do
      :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{n: n})
    end

    _ = Stats.snapshot()
    assert length(Stats.snapshot().recent) <= 50
  end
end
