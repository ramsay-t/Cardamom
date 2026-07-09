defmodule Cardamom.Ledger.DeltaTest do
  @moduledoc """
  The invertible delta op vocabulary. MC/DC-style: each op FORM (:add/:put/:del/:set) is a clause
  of both invert/1 and apply_op/1, so we drive each independently — and assert the defining
  property: for every op, applying it then its inverse is a no-op. See test/TEST_STRATEGY.md.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Delta

  # invert/1 — one clause per op form (MC/DC: each selected independently) --------------------

  test "invert :add negates the amount" do
    assert Delta.invert({:add, :fees, :pot, 100}) == {:add, :fees, :pot, -100}
  end

  test "invert :put is :del (capturing the value to restore)" do
    assert Delta.invert({:put, :deposit, :k, 5}) == {:del, :deposit, :k, 5}
  end

  test "invert :del is :put (restoring the captured old value)" do
    assert Delta.invert({:del, :deposit, :k, 5}) == {:put, :deposit, :k, 5}
  end

  test "invert :set swaps old<->new (the overwrite case — needs the captured old)" do
    assert Delta.invert({:set, :stake_deleg, :c, "poolA", "poolB"}) ==
             {:set, :stake_deleg, :c, "poolB", "poolA"}
  end

  # invert is an involution: invert(invert(op)) == op, per form -------------------------------

  test "invert is self-cancelling for every op form" do
    for op <- [
          {:add, :fees, :p, 7},
          {:put, :deposit, :k, 3},
          {:del, :deposit, :k, 3},
          {:set, :pool, :x, "old", "new"}
        ] do
      assert Delta.invert(Delta.invert(op)) == op
    end
  end

  # domain?/1 — the closed set guard (MC/DC: a member vs a non-member) ------------------------

  test "domain? accepts known domains and rejects unknown" do
    assert Delta.domain?(:fees)
    assert Delta.domain?(:stake_deleg)
    refute Delta.domain?(:not_a_domain)
  end
end
