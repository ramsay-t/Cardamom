defmodule Cardamom.Ledger.RatifyTest do
  @moduledoc """
  Ratification acceptance predicate (Conway Ratify.lagda.md §acceptedBy). A body ACCEPTS a gov
  action iff `acceptedStake / totalStake ≥ threshold`, where (Ratify.lagda.md:352-357):
    * acceptedStake = Σ stake of YES voters,
    * totalStake    = Σ stake of (YES ∪ NO) voters — ABSTAIN and non-voters excluded from the
      denominator (an abstention is not a no),
    * threshold `nothing` for a body ⇒ that body auto-accepts (⊤).
  An action is ratified iff ALL three bodies (CC, DRep, SPO) accept.

  Comparison is exact via cross-multiplication (accepted·t_den ≥ t_num·total), no float, no
  rational division. Stake per voter is INJECTED (`stake_of`) — DRep/SPO stake-weighted from the
  reward-engine snapshots; CC counts 1 per active member (constMap 1, Ratify.lagda.md:344).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Ratify

  # votes: %{voter => :yes | :no | :abstain}; stake: %{voter => coin}; threshold {num, den} | nil
  defp accepted?(votes, stake, threshold),
    do: Ratify.body_accepts?(votes, fn v -> Map.get(stake, v, 0) end, threshold)

  test "yes stake over the threshold accepts; under rejects" do
    votes = %{a: :yes, b: :yes, c: :no}
    stake = %{a: 60, b: 10, c: 30}
    # yes = 70, total(yes∪no) = 100 → 0.70
    assert accepted?(votes, stake, {1, 2})
    refute accepted?(votes, stake, {3, 4})
  end

  test "exact boundary: ratio == threshold accepts (≥, not >)" do
    votes = %{a: :yes, b: :no}
    stake = %{a: 1, b: 1}
    assert accepted?(votes, stake, {1, 2}), "50/50 meets a 1/2 threshold"
  end

  test "ABSTAIN is excluded from the denominator (not a no)" do
    votes = %{a: :yes, b: :abstain, c: :abstain}
    stake = %{a: 5, b: 100, c: 100}
    # yes=5, total(yes∪no)=5 → 1.0 despite the huge abstaining stake
    assert accepted?(votes, stake, {3, 4})
  end

  test "no votes at all → 0/0: with a real threshold, does NOT accept" do
    assert Ratify.body_accepts?(%{}, fn _ -> 0 end, {1, 2}) == false
  end

  test "threshold nil ⇒ body auto-accepts (⊤), regardless of votes" do
    assert Ratify.body_accepts?(%{a: :no}, fn _ -> 100 end, nil)
  end

  test "CC counts by MEMBER (stake_of returns 1 each), not by coin" do
    votes = %{m1: :yes, m2: :yes, m3: :no}
    one = fn _ -> 1 end
    assert Ratify.body_accepts?(votes, one, {1, 2}), "2 of 3 = 0.67 ≥ 0.5"
    refute Ratify.body_accepts?(votes, one, {7, 10}), "0.67 < 0.7"
  end

  describe "ratified? — all three bodies must accept" do
    test "accepts only when CC ∧ DRep ∧ SPO all accept" do
      # per body: {votes, stake_fn, threshold}
      pass = {%{a: :yes}, fn _ -> 10 end, {1, 2}}
      fail = {%{a: :no}, fn _ -> 10 end, {1, 2}}

      assert Ratify.ratified?(%{cc: pass, drep: pass, spo: pass})
      refute Ratify.ratified?(%{cc: pass, drep: fail, spo: pass})
    end

    test "a body with a nil threshold doesn't block ratification" do
      pass = {%{a: :yes}, fn _ -> 10 end, {1, 2}}
      auto = {%{}, fn _ -> 0 end, nil}
      assert Ratify.ratified?(%{cc: auto, drep: pass, spo: pass})
    end
  end
end
