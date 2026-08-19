defmodule Cardamom.Ledger.Ratify.Threshold do
  @moduledoc """
  The ratification THRESHOLD table (Conway Ratify.lagda.md:108, `threshold pp ccThreshold ga`):
  per gov action, the (CC, DRep, SPO) acceptance thresholds that `Cardamom.Ledger.Ratify` compares
  the tally against. `nil` for a body = it has no vote on this action (spec `─`, auto-accept).

  Spec table (columns CC | DRep | SPO):

      NoConfidence        ─   | P1            | Q1
      UpdateCommittee     ─   | P2a/b         | Q2a/b        a: committee exists · b: no-confidence
      NewConstitution     ✓   | P3            | ─
      TriggerHardFork     ✓   | P4            | Q4
      ChangePParams       ✓   | max P5* / grp | Q5 iff Security group touched
      TreasuryWithdrawal  ✓   | P6            | ─
      Info                ✓†  | ✓†            | ✓†

  DRep P* come from `dRepVotingThresholds`, SPO Q* from `poolVotingThresholds` (both per-network,
  passed in). CC `✓` = the committee threshold when a committee exists, else `defer`. `defer`
  ({2,1} = 1+1) is a >1 sentinel that can never be met — it BLOCKS the action: Info actions never
  enact, and a `✓` action can't pass while there is no committee. For `ChangePParams`, the DRep
  threshold is the MAX over the param groups the update touches (Ratify.lagda.md:150-156); the SPO
  threshold applies only if the update touches the Security group.

  Thresholds are `{num, den}` unit-interval fractions (or `nil`), the shape `Ratify.body_accepts?`
  cross-multiplies against.

  `of(action, params)` — `action` is `%{action: type, [param_groups: [..]]}` (from
  `Cardamom.Ledger.Conway.Governance`); `params` is `%{drep:, spo:, cc_threshold:, no_confidence?:}`.
  """

  # `defer` = 1+1: an unmeetable threshold (Ratify.lagda.md `defer = 1ℚ + 1ℚ`).
  @defer {2, 1}

  def of(%{action: action} = ga, params) do
    drep = params.drep
    spo = params.spo

    case action do
      :no_confidence ->
        %{cc: nil, drep: drep.motion_no_confidence, spo: spo.motion_no_confidence}

      :update_committee ->
        if params.no_confidence? do
          %{cc: nil, drep: drep.committee_no_confidence, spo: spo.committee_no_confidence}
        else
          %{cc: nil, drep: drep.committee_normal, spo: spo.committee_normal}
        end

      :new_constitution ->
        %{cc: cc(params), drep: drep.update_constitution, spo: nil}

      :hard_fork_initiation ->
        %{cc: cc(params), drep: drep.hard_fork, spo: spo.hard_fork}

      :treasury_withdrawals ->
        %{cc: cc(params), drep: drep.treasury_withdrawal, spo: nil}

      :parameter_change ->
        groups = Map.get(ga, :param_groups, [])
        %{cc: cc(params), drep: drep_pp_threshold(groups, drep), spo: spo_pp_threshold(groups, spo)}

      :info_action ->
        %{cc: @defer, drep: @defer, spo: @defer}

      _ ->
        # Unknown action: defer everything (fail-closed — an action we can't classify can't enact).
        %{cc: @defer, drep: @defer, spo: @defer}
    end
  end

  # CC ✓: the committee threshold if a committee exists, else defer (blocks until one does).
  defp cc(%{cc_threshold: nil}), do: @defer
  defp cc(%{cc_threshold: t}), do: t

  # DRep ChangePParams: max threshold over the touched param groups (Network/Economic/Technical/
  # Governance each have a DRep threshold; Security does not — it's the SPO's).
  defp drep_pp_threshold(groups, drep) do
    groups
    |> Enum.map(fn
      :network -> drep.pp_network
      :economic -> drep.pp_economic
      :technical -> drep.pp_technical
      :gov -> drep.pp_gov
      :security -> nil
      _ -> nil
    end)
    |> max_threshold()
  end

  # SPO ChangePParams: applies ONLY when the Security group is touched (Q5 = ppSecurityGroup).
  defp spo_pp_threshold(groups, spo) do
    if :security in groups, do: spo.pp_security, else: nil
  end

  # Max of a list of {num,den}|nil thresholds; nils drop out; all-nil ⇒ nil.
  defp max_threshold(list) do
    list
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(nil, fn t, acc ->
      cond do
        acc == nil -> t
        gte?(t, acc) -> t
        true -> acc
      end
    end)
  end

  # {a,b} ≥ {c,d}  ⟺  a·d ≥ c·b  (positive denominators).
  defp gte?({a, b}, {c, d}), do: a * d >= c * b
end
