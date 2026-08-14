defmodule Cardamom.Ledger.Conway.Governance do
  @moduledoc """
  Decode Conway GOVERNANCE tx-body fields to INERT terms (Harvard boundary): proposal_procedures
  (body key 20) and — later — voting_procedures (key 19). Authoritative shapes: conway.cddl.

      proposal_procedure = [deposit : coin, reward_account, gov_action, anchor]
      gov_action (leading tag):
        0 parameter_change_action (…, protocol_param_update, …)
        1 hard_fork_initiation_action (…, protocol_version)
        2 treasury_withdrawals_action  3 no_confidence  4 update_committee
        5 new_constitution  6 info_action (= 6, not an array)
      protocol_param_update = { ?0:minFeeA ?1:minFeeB … ?17:coinsPerUTxOByte … }

  Two immediate consumers:
    * `total_deposit/1` — Σ govActionDeposit over a tx's proposals: the `produced` term that made
      the value-conservation oracle SKIP proposal txs. With this it can balance them.
    * `param_updates/1` — the protocol_param_update maps from parameter-change proposals: the
      input to enacted-param tracking (which turns the min_fee / min_ada rules from skip to
      assert). NB a PROPOSAL is not yet ENACTED — tracking enactment (ratification, the epoch gov
      half) is a further step; this only decodes what a tx proposes.

  Strict-ish but non-raising: unknown/malformed actions decode to `:unknown` (a new gov-action
  type can't crash ingestion), same discipline as the cert decoder.
  """

  # protocol_param_update keys we currently care about (conway.cddl); others kept unmapped.
  @ppu_keys %{0 => :min_fee_a, 1 => :min_fee_b, 17 => :coins_per_utxo_byte}

  @doc "Σ of govActionDeposit across a tx's proposals (bare list or #6.258 set; nil → 0)."
  def total_deposit(proposals) do
    proposals
    |> unset()
    |> Enum.reduce(0, fn p, acc -> acc + deposit_of(p) end)
  end

  @doc "The protocol_param_update maps from all parameter-change proposals in the list."
  def param_updates(proposals) do
    proposals
    |> unset()
    |> Enum.map(&decode_proposal/1)
    |> Enum.filter(&(&1.action == :parameter_change and is_map(&1[:param_update])))
    |> Enum.map(& &1.param_update)
  end

  @doc """
  Decode one proposal_procedure to `%{deposit, reward_account, action, [param_update]}`. `action`
  is the gov-action type atom; `param_update` present only for `:parameter_change`.
  """
  def decode_proposal([deposit, reward_account | rest]) when is_integer(deposit) do
    gov_action = Enum.at(rest, 0)
    base = %{deposit: deposit, reward_account: unbytes(reward_account), action: action_type(gov_action)}

    case base.action do
      :parameter_change -> Map.put(base, :param_update, decode_param_update(param_update_of(gov_action)))
      _ -> base
    end
  end

  def decode_proposal(_), do: %{deposit: 0, action: :unknown, reward_account: nil}

  # ---- gov action typing ----

  defp action_type([0 | _]), do: :parameter_change
  defp action_type([1 | _]), do: :hard_fork_initiation
  defp action_type([2 | _]), do: :treasury_withdrawals
  defp action_type([3 | _]), do: :no_confidence
  defp action_type([4 | _]), do: :update_committee
  defp action_type([5 | _]), do: :new_constitution
  defp action_type([6 | _]), do: :info_action
  # info_action is `= 6` (a bare int), not an array, in the CDDL
  defp action_type(6), do: :info_action
  defp action_type(_), do: :unknown

  # parameter_change_action = (0, gov_action_id/nil, protocol_param_update, guardrails/nil)
  defp param_update_of([0, _gov_action_id, ppu | _]), do: ppu
  defp param_update_of(_), do: nil

  defp decode_param_update(ppu) when is_map(ppu) do
    for {k, v} <- ppu, name = Map.get(@ppu_keys, k), name != nil, into: %{}, do: {name, v}
  end

  defp decode_param_update(_), do: %{}

  # ---- helpers ----

  defp deposit_of([deposit | _]) when is_integer(deposit), do: deposit
  defp deposit_of(_), do: 0

  defp unset(nil), do: []
  defp unset(%CBOR.Tag{tag: 258, value: list}) when is_list(list), do: list
  defp unset(list) when is_list(list), do: list
  defp unset(_), do: []

  defp unbytes(%CBOR.Tag{tag: :bytes, value: b}), do: b
  defp unbytes(b) when is_binary(b), do: b
  defp unbytes(_), do: nil
end
