defmodule Cardamom.Ledger.Ratify do
  @moduledoc """
  Ratification acceptance predicate (Conway Ratify.lagda.md §acceptedBy) — the tally that decides
  whether a governance action is ratified by a governing body, and by all three together.

  A body ACCEPTS an action iff `acceptedStake / totalStake ≥ threshold` (Ratify.lagda.md:352-357):
    * `acceptedStake` = Σ stake of YES voters,
    * `totalStake`    = Σ stake of (YES ∪ NO) voters — ABSTAIN and non-voters are excluded from
      the denominator (an abstention is deliberately not a no),
    * a `nil` threshold for a body ⇒ that body auto-accepts (the spec's `nothing → ⊤`; e.g. the
      body has no say over this action type).

  `stake_of` is INJECTED (`voter -> coin`): for DRep/SPO it's the stake-weighting from the reward
  engine's snapshots; for the Constitutional Committee each active member counts 1
  (constMap 1, Ratify.lagda.md:344) — pass `fn _ -> 1 end`. Comparison is EXACT via
  cross-multiplication (`accepted·den ≥ num·total`) — no float, no rational division.

  SCOPE: this is the acceptance MATH + the three-body AND. It does NOT here decide the threshold
  VALUES per action type (the `threshold` table — pparam/committee/no-confidence rows,
  Ratify.lagda.md:108), the CC min-size / active-member gate, DRep/SPO activity expiry, or the
  ratification DELAY. Those layer on top: `ratified?/1` takes the already-resolved per-body
  `{votes, stake_of, threshold}` so the caller supplies the table + active sets.
  """

  @type vote :: :yes | :no | :abstain
  @type body_input :: {votes :: %{optional(term()) => vote()}, stake_of :: (term() -> integer()), threshold :: {integer(), pos_integer()} | nil}

  @doc """
  Does one body accept? `votes` maps voter → :yes/:no/:abstain; `stake_of` gives a voter's weight;
  `threshold` is `{num, den}` (a unit-interval fraction) or `nil` (auto-accept). `false` when
  totalStake is 0 against a real threshold (0/0 doesn't clear a positive bar).
  """
  @spec body_accepts?(map(), (term() -> integer()), {integer(), pos_integer()} | nil) :: boolean()
  def body_accepts?(_votes, _stake_of, nil), do: true

  def body_accepts?(votes, stake_of, {num, den}) when is_map(votes) and is_integer(num) and is_integer(den) do
    {accepted, total} =
      Enum.reduce(votes, {0, 0}, fn
        {voter, :yes}, {acc, tot} -> w = stake_of.(voter); {acc + w, tot + w}
        {voter, :no}, {acc, tot} -> {acc, tot + stake_of.(voter)}
        {_voter, :abstain}, sums -> sums
        _other, sums -> sums
      end)

    # acceptedStake/total ≥ num/den  ⟺  accepted·den ≥ num·total   (total>0; 0/0 fails a real bar)
    total > 0 and accepted * den >= num * total
  end

  @doc """
  Is the action ratified — do ALL governing bodies accept? `bodies` is a map (e.g.
  `%{cc:, drep:, spo:}`) of `{votes, stake_of, threshold}` per body, already resolved by the
  caller (threshold table + active sets applied). A body whose threshold is nil doesn't block.
  """
  @spec ratified?(%{optional(atom()) => body_input()}) :: boolean()
  def ratified?(bodies) when is_map(bodies) do
    Enum.all?(bodies, fn {_body, {votes, stake_of, threshold}} ->
      body_accepts?(votes, stake_of, threshold)
    end)
  end
end
