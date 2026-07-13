defmodule Cardamom.Ledger.RationalTest do
  @moduledoc """
  Exact rationals for the reward calc. The point is EXACTNESS + correct flooring — floating point
  would diverge from the network. Tests pin the reward-relevant behaviours: reduction, floor toward
  -inf, the zero-safe ÷₀, the min(1, η) cap, and a compound expression matching a hand-computed
  fraction. MC/DC-style: div vs div_or_zero on a zero denominator are separate clauses.
  """
  use ExUnit.Case, async: true
  alias Cardamom.Ledger.Rational, as: Q

  test "new/2 normalises: positive denominator, gcd-reduced" do
    assert %{num: 1, den: 2} = Q.new(2, 4)
    assert %{num: -1, den: 2} = Q.new(1, -2)
    assert %{num: 3, den: 1} = Q.new(3)
  end

  test "arithmetic is exact (no float drift)" do
    # 1/3 + 1/6 = 1/2
    assert Q.add(Q.new(1, 3), Q.new(1, 6)) == Q.new(1, 2)
    # 2/3 * 3/4 = 1/2
    assert Q.mul(Q.new(2, 3), Q.new(3, 4)) == Q.new(1, 2)
    # (7/10) - (1/5) = 1/2
    assert Q.sub(Q.new(7, 10), Q.new(1, 5)) == Q.new(1, 2)
  end

  test "floor rounds toward -infinity (matters for the coin values)" do
    assert Q.floor(Q.new(7, 2)) == 3
    assert Q.floor(Q.new(-7, 2)) == -4
    assert Q.floor(Q.new(6, 3)) == 2
    assert Q.floor(5) == 5
  end

  test "floor_pos clamps negatives to 0 (the spec's posPart(floor ..))" do
    assert Q.floor_pos(Q.new(-1, 2)) == 0
    assert Q.floor_pos(Q.new(9, 4)) == 2
  end

  test "div raises on zero, but div_or_zero (÷₀) returns 0 — the spec's zero-safe division" do
    assert Q.div_or_zero(Q.new(5), 0) == Q.from_int(0)
    assert Q.div_or_zero(Q.new(5), Q.new(0, 1)) == Q.from_int(0)
    assert Q.div(Q.new(1), Q.new(2)) == Q.new(1, 2)
    assert_raise ArithmeticError, fn -> Q.new(1, 0) end
  end

  test "min is the ⊓ cap used for min(1, η)" do
    # η = 3/2 capped at 1 → 1
    assert Q.min(Q.from_int(1), Q.new(3, 2)) == Q.from_int(1)
    # η = 1/2 under 1 → 1/2
    assert Q.min(Q.from_int(1), Q.new(1, 2)) == Q.new(1, 2)
  end

  test "lte compares exactly across denominators" do
    assert Q.lte(Q.new(1, 3), Q.new(1, 2))
    refute Q.lte(Q.new(1, 2), Q.new(1, 3))
    assert Q.lte(Q.new(2, 4), Q.new(1, 2))
  end

  test "max/2 selects the larger, both branches" do
    assert Q.max(Q.new(1, 3), Q.new(1, 2)) == Q.new(1, 2)
    assert Q.max(Q.new(1, 2), Q.new(1, 3)) == Q.new(1, 2)
    assert Q.max(Q.from_int(5), 5) == Q.from_int(5)
  end

  test "new(0, n) reduces to 0/1 (the gcd=0 guard)" do
    assert Q.new(0, 5) == Q.from_int(0)
    assert Q.new(0, 5) == %Q{num: 0, den: 1}
  end

  test "coerce accepts a struct unchanged and an integer" do
    r = Q.new(2, 3)
    assert Q.coerce(r) == r
    assert Q.coerce(4) == Q.from_int(4)
  end

  test "a reward-shaped compound expression is exact" do
    # rewardPot/(1+a0) with rewardPot=1000, a0=3/10 → 1000/(13/10) = 10000/13
    a0 = Q.new(3, 10)
    one_plus = Q.add(Q.from_int(1), a0)
    r = Q.div(Q.from_int(1000), one_plus)
    assert r == Q.new(10000, 13)
    # floored to a coin
    assert Q.floor(r) == 769
  end
  test "coerce accepts a {num, den} pair (the wire's tag-30 shape)" do
    assert Q.coerce({3, 10}) == Q.new(3, 10)
  end

  test "clamp_unit confines to [0,1] (below, inside, above — MC/DC per bound)" do
    assert Q.clamp_unit(Q.new(-1, 2)) == Q.from_int(0)
    assert Q.clamp_unit(Q.new(1, 2)) == Q.new(1, 2)
    assert Q.clamp_unit(Q.new(3, 2)) == Q.from_int(1)
  end

  test "from_decimal! is the EXACT decimal, not the nearest double" do
    assert Q.from_decimal!("0.003") == Q.new(3, 1000)
    assert Q.from_decimal!("0.05") == Q.new(1, 20)
    assert Q.from_decimal!("1") == Q.from_int(1)
    assert Q.from_decimal!("5e-2") == Q.new(1, 20)
    assert Q.from_decimal!("1.5e2") == Q.from_int(150)
  end

  test "from_json_number: genesis floats recover their intended decimal (rho/tau/a0)" do
    assert Q.from_json_number(0.003) == Q.new(3, 1000)
    assert Q.from_json_number(0.3) == Q.new(3, 10)
    assert Q.from_json_number(0.2) == Q.new(1, 5)
    assert Q.from_json_number(45_000_000_000_000_000) == Q.from_int(45_000_000_000_000_000)
  end

end
