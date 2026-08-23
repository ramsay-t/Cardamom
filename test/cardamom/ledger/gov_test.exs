defmodule Cardamom.Ledger.GovTest do
  @moduledoc """
  GOV-action state tracking (Conway Gov.lagda.md) — the substrate ratification tallies over.
  GovState = GovActionID → GovActionState{votes, returnAddr, expiresIn, action, prevAction}.

  This slice tracks the LIFECYCLE as INVERTIBLE delta ops in a `:gov` ledger domain (journals +
  rolls back like every effect):
    * a PROPOSAL in a tx inserts a GovActionState keyed by its GovActionID (txid, index),
      with expiresIn = current_epoch + govActionLifetime,
    * a VOTE in a tx accumulates into the target action's `votes` (voter ⇒ Yes/No/Abstain),
    * (epoch expiry + enactment are the next layers — ratification.)

  Scope: this builds the STATE, not the ratification DECISION (thresholds/tallies). Votes are
  recorded; who wins is a further rule.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Gov

  defp b(x), do: %CBOR.Tag{tag: :bytes, value: x}
  defp read(m), do: fn :gov, k -> Map.get(m, k) end

  test "a proposal inserts a GovActionState keyed by (txid, index), expiring after the lifetime" do
    txid = <<7::256>>
    # one info_action proposal: [deposit, reward_account, gov_action, anchor]
    prop = [40_000_000, b(<<0xE0, 1::224>>), [6], nil]

    ops = Gov.proposal_ops(txid, [prop], epoch: 100, lifetime: 6, read: read(%{}))

    gaid = {txid, 0}
    assert [{:set, :gov, ^gaid, nil, state}] = ops
    assert state.action == :info_action
    assert state.expires_in == 106
    assert state.votes == %{}
  end

  test "multiple proposals in a tx get index-suffixed ids 0,1,…" do
    txid = <<9::256>>
    props = [
      [1, b(<<0xE0, 1::224>>), [6], nil],
      [1, b(<<0xE0, 2::224>>), [3, nil], nil]
    ]

    ops = Gov.proposal_ops(txid, props, epoch: 5, lifetime: 6, read: read(%{}))
    assert Enum.map(ops, fn {:set, :gov, id, _, _} -> id end) == [{txid, 0}, {txid, 1}]
  end

  test "a vote accumulates into the target action's votes map" do
    gaid = {<<1::256>>, 0}
    existing = %{votes: %{}, expires_in: 106, action: :info_action}
    # voting_procedures: { voter => { gov_action_id => voting_procedure } }
    voter = {:drep, b(<<3::224>>)}
    votes = %{voter => %{gaid => %{vote: :yes}}}

    ops = Gov.vote_ops(votes, read: read(%{gaid => existing}))

    assert [{:set, :gov, ^gaid, ^existing, updated}] = ops
    assert updated.votes[voter] == :yes
  end

  test "a vote for an unknown action is dropped (can't vote on what isn't proposed)" do
    gaid = {<<9::256>>, 0}
    votes = %{{:drep, b(<<3::224>>)} => %{gaid => %{vote: :no}}}
    assert Gov.vote_ops(votes, read: read(%{})) == []
  end

  test "proposal + votes compose: same-tx overlay sees the just-inserted action" do
    txid = <<5::256>>
    prop = [1, b(<<0xE0, 1::224>>), [6], nil]
    gaid = {txid, 0}

    prop_ops = Gov.proposal_ops(txid, [prop], epoch: 1, lifetime: 6, read: read(%{}))
    # build an overlay read that reflects the proposal op, then vote on it
    overlay = fn :gov, ^gaid -> (fn -> {:set, :gov, ^gaid, _, s} = hd(prop_ops); s end).() end
    votes = %{{:drep, b(<<3::224>>)} => %{gaid => %{vote: :abstain}}}

    assert [{:set, :gov, ^gaid, _old, updated}] = Gov.vote_ops(votes, read: overlay)
    assert updated.votes[{:drep, b(<<3::224>>)}] == :abstain
  end

  test "malformed proposals/votes are skipped, never raise" do
    assert Gov.proposal_ops(<<0::256>>, :garbage, epoch: 1, lifetime: 6, read: read(%{})) == []
    assert Gov.vote_ops(:garbage, read: read(%{})) == []
  end

  # MC/DC per clause: the RAW voting_procedure vote encodings (the wire shape [vote, anchor]),
  # not just the pre-decoded %{vote: v}. vote 0/1/2 = no/yes/abstain; anything else :unknown.
  test "raw voting_procedure encodings map 0/1/2 → no/yes/abstain, else :unknown" do
    gaid = {<<1::256>>, 0}
    st = %{votes: %{}, expires_in: 9, action: :info_action}
    voter = {:drep, b(<<3::224>>)}

    for {enc, expected} <- [{[0, nil], :no}, {[1, nil], :yes}, {[2, nil], :abstain}, {[9, nil], :unknown}] do
      votes = %{voter => %{gaid => enc}}
      assert [{:set, :gov, ^gaid, ^st, updated}] = Gov.vote_ops(votes, read: read(%{gaid => st}))
      assert updated.votes[voter] == expected
    end
  end

  # MC/DC: proposal list arrives as a #6.258 SET tag as well as a bare list.
  test "proposal_ops accepts a #6.258 set-wrapped proposal list" do
    txid = <<8::256>>
    set = %CBOR.Tag{tag: 258, value: [[1, b(<<0xE0, 1::224>>), [6], nil]]}
    assert [{:set, :gov, {^txid, 0}, nil, _}] =
             Gov.proposal_ops(txid, set, epoch: 1, lifetime: 6, read: read(%{}))
  end

  # MC/DC: an unknown gov-action in a proposal is skipped (no state inserted).
  test "an unknown gov action in a proposal produces no gov op" do
    txid = <<4::256>>
    prop = [1, b(<<0xE0, 1::224>>), [99, :junk], nil]
    assert Gov.proposal_ops(txid, [prop], epoch: 1, lifetime: 6, read: read(%{})) == []
  end
end
