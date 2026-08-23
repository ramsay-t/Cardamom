defmodule Cardamom.Ledger.Conway.GovernanceTest do
  @moduledoc """
  Decode Conway GOVERNANCE tx-body fields (kept raw until now): proposal_procedures (key 20) and
  voting_procedures (key 19). To INERT terms (Harvard boundary). CDDL (conway.cddl):

    proposal_procedure = [deposit : coin, reward_account, gov_action, anchor]
    gov_action union (leading tag):
      0 parameter_change (…, protocol_param_update, …)  1 hard_fork_initiation
      2 treasury_withdrawals  3 no_confidence  4 update_committee
      5 new_constitution  6 info_action
    protocol_param_update = { ?0:minFeeA ?1:minFeeB … ?17:coinsPerUTxOByte … }

  Two immediate consumers: the govActionDeposit sum (conservation currently SKIPS proposal txs)
  and the protocol_param_update map (the input to pp-tracking → turns min_fee/min_ada from skip
  to assert).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Conway.Governance

  defp b(x), do: %CBOR.Tag{tag: :bytes, value: x}

  test "proposals: sum of govActionDeposits across a proposal list" do
    props = [
      [50_000_000, b(<<0xE0, 1::224>>), [6], [b("url"), b(<<0::256>>)]],
      [50_000_000, b(<<0xE0, 2::224>>), [3, nil], [b("u2"), b(<<1::256>>)]]
    ]

    assert Governance.total_deposit(props) == 100_000_000
  end

  test "proposals: total_deposit handles the #6.258 set wrapper and nil/empty" do
    props = %CBOR.Tag{tag: 258, value: [[7_000_000, b(<<0xE0, 1::224>>), [6], nil]]}
    assert Governance.total_deposit(props) == 7_000_000
    assert Governance.total_deposit(nil) == 0
    assert Governance.total_deposit([]) == 0
  end

  test "decode_proposal: extracts deposit, gov-action TYPE, and reward account" do
    prop = [40_000_000, b(<<0xE0, 9::224>>), [6], nil]
    assert %{deposit: 40_000_000, action: :info_action, reward_account: <<0xE0, 9::224>>} =
             Governance.decode_proposal(prop)
  end

  test "decode_proposal: every gov-action tag maps to its name" do
    mk = fn action -> [1, b(<<0xE0, 0::224>>), action, nil] end
    assert Governance.decode_proposal(mk.([0, nil, %{}, nil])).action == :parameter_change
    assert Governance.decode_proposal(mk.([1, nil, [10, 0]])).action == :hard_fork_initiation
    assert Governance.decode_proposal(mk.([2, %{}, nil])).action == :treasury_withdrawals
    assert Governance.decode_proposal(mk.([3, nil])).action == :no_confidence
    assert Governance.decode_proposal(mk.([4, nil, %{}, %{}, [1, 2]])).action == :update_committee
    assert Governance.decode_proposal(mk.([5, nil, [nil, nil]])).action == :new_constitution
    assert Governance.decode_proposal(mk.([6])).action == :info_action
  end

  test "parameter_change: the protocol_param_update map is surfaced (minFeeA/B, coinsPerUTxOByte)" do
    ppu = %{0 => 50, 1 => 200_000, 17 => 4310}
    prop = [40_000_000, b(<<0xE0, 0::224>>), [0, nil, ppu, nil], nil]

    decoded = Governance.decode_proposal(prop)
    assert decoded.action == :parameter_change
    assert decoded.param_update == %{min_fee_a: 50, min_fee_b: 200_000, coins_per_utxo_byte: 4310}
  end

  test "param_updates: collect all param-change updates across a proposal list" do
    props = [
      [1, b(<<0xE0, 0::224>>), [0, nil, %{0 => 44}, nil], nil],
      [1, b(<<0xE0, 1::224>>), [6], nil]
    ]

    assert Governance.param_updates(props) == [%{min_fee_a: 44}]
  end

  test "malformed / unknown gov action → :unknown, never raises" do
    assert Governance.decode_proposal([1, b(<<0xE0, 0::224>>), [99, :junk], nil]).action == :unknown
    assert Governance.decode_proposal(:garbage) == %{deposit: 0, action: :unknown, reward_account: nil}
  end

  # MC/DC per clause: defensive fallthroughs.
  test "info_action in the bare-int form (= 6, not an array) is recognised" do
    prop = [1, b(<<0xE0, 0::224>>), 6, nil]
    assert Governance.decode_proposal(prop).action == :info_action
  end

  test "total_deposit skips non-integer-deposit entries; unset handles set-tag + junk" do
    # a malformed proposal (no integer deposit) contributes 0
    assert Governance.total_deposit([[:no_deposit, :x], [5, :y]]) == 5
    assert Governance.total_deposit(%CBOR.Tag{tag: 258, value: [[7, :z]]}) == 7
    assert Governance.total_deposit(:garbage) == 0
  end

  test "parameter_change with a non-map param_update yields an empty update map" do
    prop = [1, b(<<0xE0, 0::224>>), [0, nil, :not_a_map, nil], nil]
    assert Governance.decode_proposal(prop).param_update == %{}
  end

  test "a reward_account that isn't bytes decodes to nil (unbytes fallthrough)" do
    prop = [1, :not_bytes, [6], nil]
    assert Governance.decode_proposal(prop).reward_account == nil
  end
end
