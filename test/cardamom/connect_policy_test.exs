defmodule Cardamom.ConnectPolicyTest do
  @moduledoc """
  The connection guard's POLICY is pure and time-driven, so we test it with an
  explicit clock (no real waiting). It enforces politeness — connection RATE, not
  message rate: single attempt at a time, a minimum cooldown between connects to
  the same endpoint, exponential backoff on repeated failures, and a circuit
  breaker after too many failures. (We got a connect-timeout after dialing the
  Preview relay 4x in 25min — this is what stops that.)
  """
  use ExUnit.Case, async: true

  alias Cardamom.ConnectPolicy

  @ep {"relay", 3001}

  test "first attempt is allowed immediately" do
    p = ConnectPolicy.new()
    assert {:ok, _p} = ConnectPolicy.allow(p, @ep, now_ms: 0)
  end

  test "a second attempt within the cooldown is denied" do
    p = ConnectPolicy.new(cooldown_ms: 10_000)
    {:ok, p} = ConnectPolicy.allow(p, @ep, now_ms: 0)
    p = ConnectPolicy.connected(p, @ep, now_ms: 100)
    p = ConnectPolicy.disconnected(p, @ep, now_ms: 200)

    assert {:wait, ms, _p} = ConnectPolicy.allow(p, @ep, now_ms: 1_000)
    assert ms > 0
  end

  test "after the cooldown elapses, a new attempt is allowed" do
    p = ConnectPolicy.new(cooldown_ms: 10_000)
    {:ok, p} = ConnectPolicy.allow(p, @ep, now_ms: 0)
    p = ConnectPolicy.connected(p, @ep, now_ms: 100)
    p = ConnectPolicy.disconnected(p, @ep, now_ms: 200)

    assert {:ok, _p} = ConnectPolicy.allow(p, @ep, now_ms: 11_000)
  end

  test "repeated failures back off exponentially" do
    p = ConnectPolicy.new(base_backoff_ms: 1_000, cooldown_ms: 0)
    {:ok, p} = ConnectPolicy.allow(p, @ep, now_ms: 0)
    p = ConnectPolicy.failed(p, @ep, now_ms: 100)
    {:wait, w1, p} = ConnectPolicy.allow(p, @ep, now_ms: 200)

    p = ConnectPolicy.failed(p, @ep, now_ms: w1 + 300)
    {:wait, w2, _p} = ConnectPolicy.allow(p, @ep, now_ms: w1 + 400)

    assert w2 > w1, "backoff grows with consecutive failures (#{w1} -> #{w2})"
  end

  test "a successful connection resets the backoff" do
    p = ConnectPolicy.new(base_backoff_ms: 1_000, cooldown_ms: 0)
    {:ok, p} = ConnectPolicy.allow(p, @ep, now_ms: 0)
    p = ConnectPolicy.failed(p, @ep, now_ms: 100)
    p = ConnectPolicy.failed(p, @ep, now_ms: 5_000)
    # now a success
    p = ConnectPolicy.connected(p, @ep, now_ms: 10_000)
    p = ConnectPolicy.disconnected(p, @ep, now_ms: 11_000)

    # backoff should be reset (next wait, if any, is just the cooldown, not escalated)
    assert {:ok, _p} = ConnectPolicy.allow(p, @ep, now_ms: 20_000)
  end

  test "circuit breaker: after max consecutive failures, attempts are blocked for a long window" do
    p = ConnectPolicy.new(base_backoff_ms: 100, max_failures: 3, breaker_ms: 60_000, cooldown_ms: 0)

    p =
      Enum.reduce(1..3, p, fn i, p ->
        {_, _, p} = allow_any(p, @ep, i * 1_000)
        ConnectPolicy.failed(p, @ep, now_ms: i * 1_000 + 1)
      end)

    assert {:wait, ms, _p} = ConnectPolicy.allow(p, @ep, now_ms: 3_500)
    assert ms >= 50_000, "breaker should impose a long cooldown, got #{ms}"
  end

  defp allow_any(p, ep, now) do
    case ConnectPolicy.allow(p, ep, now_ms: now) do
      {:ok, p} -> {:ok, 0, p}
      {:wait, ms, p} -> {:wait, ms, p}
    end
  end
end
