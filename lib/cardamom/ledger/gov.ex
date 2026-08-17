defmodule Cardamom.Ledger.Gov do
  @moduledoc """
  GOV-action state tracking (Conway Gov.lagda.md) — the substrate ratification tallies over.
  Spec: `GovState = GovActionID → GovActionState{votes, returnAddr, expiresIn, action, prevAction}`
  (Gov/Actions.lagda.md:387). We track the lifecycle as INVERTIBLE delta ops in a `:gov` ledger
  domain, so it journals + rolls back exactly like every other ledger effect.

  This slice builds the STATE:
    * `proposal_ops/2` — a tx's proposals insert one GovActionState each, keyed by GovActionID
      `{txid, index}`, with `expires_in = current_epoch + govActionLifetime` and empty votes;
    * `vote_ops/2` — a tx's voting_procedures accumulate `voter ⇒ vote` into the target action's
      `votes` map (a vote for an unknown action is dropped — you can't vote on an unproposed one).

  NOT here (the RATIFICATION layer, next): tallying votes against DRep/SPO/committee thresholds,
  deciding acceptance, enactment, epoch expiry + deposit refund. Votes are recorded; who wins is a
  further rule. Uses `Cardamom.Ledger.Conway.Governance` to decode proposal shapes.

  `opts`: `:epoch` (current), `:lifetime` (govActionLifetime in epochs), `:read` — the ledger
  reader `(:gov, gov_action_id) -> GovActionState | nil` (pass a read-through overlay for same-tx
  visibility, as the block handler does for other effects).
  """

  alias Cardamom.Ledger.Conway.Governance

  @doc "Delta ops inserting a GovActionState per proposal in `proposals` (bare list or #6.258)."
  def proposal_ops(txid, proposals, opts) when is_binary(txid) do
    epoch = Keyword.fetch!(opts, :epoch)
    lifetime = Keyword.fetch!(opts, :lifetime)
    read = Keyword.fetch!(opts, :read)

    proposals
    |> unset()
    |> Enum.with_index()
    |> Enum.flat_map(fn {prop, ix} ->
      case Governance.decode_proposal(prop) do
        %{action: :unknown} ->
          []

        decoded ->
          gaid = {txid, ix}

          state = %{
            votes: %{},
            return_addr: decoded.reward_account,
            expires_in: epoch + lifetime,
            action: decoded.action
          }

          [{:set, :gov, gaid, read.(:gov, gaid), state}]
      end
    end)
  end

  def proposal_ops(_txid, _proposals, _opts), do: []

  @doc """
  Delta ops accumulating votes. `voting_procedures` is the tx's key-19 map
  `{ voter => { gov_action_id => voting_procedure } }`; each inner entry folds `voter ⇒ vote`
  into the target action's `votes`. Votes for unknown actions are dropped.
  """
  def vote_ops(voting_procedures, opts) when is_map(voting_procedures) do
    read = Keyword.fetch!(opts, :read)

    voting_procedures
    |> Enum.flat_map(fn {voter, per_action} ->
      for {gaid, vp} <- per_action, do: {voter, gaid, vote_of(vp)}
    end)
    |> Enum.reduce([], fn {voter, gaid, vote}, ops ->
      # Read through the ops we've built so far so multiple votes in one tx accumulate.
      current = current_state(gaid, ops, read)

      case current do
        nil ->
          ops

        state ->
          updated = %{state | votes: Map.put(state.votes, voter, vote)}
          ops ++ [{:set, :gov, gaid, state, updated}]
      end
    end)
  end

  def vote_ops(_voting_procedures, _opts), do: []

  # Latest state for gaid: the newest op we've built this call, else the ledger read.
  defp current_state(gaid, ops, read) do
    case Enum.reverse(ops) |> Enum.find(fn {:set, :gov, id, _o, _n} -> id == gaid end) do
      {:set, :gov, ^gaid, _old, new} -> new
      _ -> read.(:gov, gaid)
    end
  end

  # voting_procedure = [vote, anchor / nil]; vote 0 No, 1 Yes, 2 Abstain (conway.cddl).
  defp vote_of(%{vote: v}), do: v
  defp vote_of([0 | _]), do: :no
  defp vote_of([1 | _]), do: :yes
  defp vote_of([2 | _]), do: :abstain
  defp vote_of(_), do: :unknown

  defp unset(nil), do: []
  defp unset(%CBOR.Tag{tag: 258, value: l}) when is_list(l), do: l
  defp unset(l) when is_list(l), do: l
  defp unset(_), do: []
end
