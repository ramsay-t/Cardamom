defmodule Cardamom.Ledger.Ratify.ThresholdTest do
  @moduledoc """
  The ratification THRESHOLD table (Ratify.lagda.md:108 `threshold pp ccThreshold ga`). Per gov
  action it returns the (CC, DRep, SPO) thresholds; `nil` = that body has no vote (─, auto-accept).

  Spec table (columns CC | DRep | SPO):
    NoConfidence       ─  | P1  | Q1
    UpdateCommittee    ─  | P2a/b | Q2a/b     (a = committee exists, b = no-confidence)
    NewConstitution    ✓  | P3  | ─
    TriggerHardFork    ✓  | P4  | Q4
    ChangePParams      ✓  | max P5* over touched groups | Q5 iff SecurityGroup touched
    TreasuryWithdrawal ✓  | P6  | ─
    Info               ✓† | ✓†  | ✓†          (defer = unmeetable sentinel)

  DRep P* ← dRepVotingThresholds; SPO Q* ← poolVotingThresholds; CC ✓ = ccThreshold (or `defer`
  when no committee). `defer = {2,1}` (1+1) — a >1 threshold that can never be met, blocking the
  action (Info can't be enacted; a missing committee blocks ✓ actions).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Ratify.Threshold

  # Preview conway-genesis values as {num, den}
  @drep %{
    motion_no_confidence: {67, 100}, committee_normal: {67, 100}, committee_no_confidence: {60, 100},
    update_constitution: {75, 100}, hard_fork: {60, 100},
    pp_network: {67, 100}, pp_economic: {67, 100}, pp_technical: {67, 100}, pp_gov: {75, 100},
    treasury_withdrawal: {67, 100}
  }
  @spo %{
    committee_normal: {51, 100}, committee_no_confidence: {51, 100}, hard_fork: {51, 100},
    motion_no_confidence: {51, 100}, pp_security: {51, 100}
  }
  @params %{drep: @drep, spo: @spo, cc_threshold: {67, 100}, no_confidence?: false}
  @defer {2, 1}

  defp t(action, opts \\ []) do
    Threshold.of(action, Enum.into(opts, @params))
  end

  test "NoConfidence: CC has no say; DRep P1, SPO Q1" do
    assert t(%{action: :no_confidence}) ==
             %{cc: nil, drep: {67, 100}, spo: {51, 100}}
  end

  test "TreasuryWithdrawal: CC + DRep vote, SPO does not" do
    assert %{cc: {67, 100}, drep: {67, 100}, spo: nil} = t(%{action: :treasury_withdrawals})
  end

  test "NewConstitution: CC + DRep, no SPO" do
    assert %{cc: {67, 100}, drep: {75, 100}, spo: nil} = t(%{action: :new_constitution})
  end

  test "TriggerHardFork: all three bodies" do
    assert %{cc: {67, 100}, drep: {60, 100}, spo: {51, 100}} = t(%{action: :hard_fork_initiation})
  end

  test "UpdateCommittee: normal uses P2a/Q2a; under no-confidence uses P2b/Q2b" do
    normal = t(%{action: :update_committee})
    assert %{cc: nil, drep: {67, 100}, spo: {51, 100}} = normal

    nc = t(%{action: :update_committee}, no_confidence?: true)
    assert %{cc: nil, drep: {60, 100}, spo: {51, 100}} = nc
  end

  test "ChangePParams: DRep threshold = MAX over the param groups the update touches" do
    # touching network (0.67) and gov (0.75) → DRep max = 0.75; no security → SPO nil
    r = t(%{action: :parameter_change, param_groups: [:network, :gov]})
    assert %{cc: {67, 100}, drep: {75, 100}, spo: nil} = r
  end

  test "ChangePParams touching the SECURITY group brings in the SPO threshold Q5" do
    r = t(%{action: :parameter_change, param_groups: [:economic, :security]})
    assert %{drep: {67, 100}, spo: {51, 100}} = r
  end

  test "Info: every body gets the `defer` sentinel (>1, unmeetable — Info never enacts)" do
    assert t(%{action: :info_action}) == %{cc: @defer, drep: @defer, spo: @defer}
  end

  test "✓ with NO committee defers CC (the action can't pass until a committee exists)" do
    r = t(%{action: :treasury_withdrawals}, cc_threshold: nil)
    assert r.cc == @defer
  end

  # MC/DC per clause: the max-over-groups edge cases and the unknown-action fallthrough.
  test "ChangePParams touching NO known groups → DRep threshold nil (max of empty)" do
    r = t(%{action: :parameter_change, param_groups: []})
    assert r.drep == nil and r.spo == nil
  end

  test "ChangePParams max picks the SMALLER-first then LARGER (gte? both branches)" do
    # gov (0.75) then economic (0.67): first sets acc, second is not ≥ → acc stays 0.75
    assert t(%{action: :parameter_change, param_groups: [:gov, :economic]}).drep == {75, 100}
    # economic (0.67) then gov (0.75): second IS ≥ → replaces → 0.75
    assert t(%{action: :parameter_change, param_groups: [:economic, :gov]}).drep == {75, 100}
  end

  test "an unknown gov action defers every body (fail-closed)" do
    assert t(%{action: :some_future_action}) == %{cc: @defer, drep: @defer, spo: @defer}
  end
end
