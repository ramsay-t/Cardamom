defmodule Cardamom.Ledger.Rewards do
  @moduledoc """
  The REWARD CALCULATION — how one epoch's reward pot is divided among stake pools and their
  delegators. A direct transcription of the Conway spec's reward functions
  (Rewards.lagda.md:134-470), computed in EXACT rationals (`Cardamom.Ledger.Rational`) with
  `floor` applied only where the spec applies it — the spec is explicit that floats are NOT
  suitable here (Rewards.lagda.md:98-114).

  Everything in this module is PURE: coins are integers, relative stakes are rationals, maps are
  plain maps. The caller (Cardamom.Ledger.EpochTransition) supplies the snapshot data; nothing
  here touches a process or the store.

  Spec function → our function:

    maxPool               (:177-217) → max_pool/4
    mkApparentPerformance (:232-248) → apparent_performance/3
    rewardOwners          (:276-284) → reward_owners/4
    rewardMember          (:286-295) → reward_member/4
    rewardOnePool         (:336-366) → reward_one_pool/9
    poolStake             (:383-385) → pool_stake/3
    reward                (:453-470) → reward/7

  `pp` is a map with `:a0` (rational-able) and `:nopt` (integer). Pool params are the decoded
  pool-registration cert map (`Cardamom.Ledger.Conway.Cert`): `:pledge`/`:cost` coins,
  `:margin` a {num, den} unit interval, `:owners` a list of 28-byte key hashes,
  `:reward_account` the raw reward-address bytes. Credentials are `{:key, h} | {:script, h}`.
  """

  alias Cardamom.Ledger.Address
  alias Cardamom.Ledger.Rational, as: Q

  @doc """
  maxPool (Rewards.lagda.md:177-217): the maximum reward a pool can earn this epoch, given the
  total `reward_pot`, the pool's relative `stake` σ and relative `pledge`, under the saturation
  cap z0 = 1/nopt and the pledge-incentive parameter a0. Both σ and pledge are capped at z0
  (saturation); a0 is floored at 0; nopt at 1. Returns a coin (posPart ∘ floor).
  """
  def max_pool(pp, reward_pot, stake, pledge) do
    a0 = Q.max(0, Q.coerce(pp.a0))
    one_plus_a0 = Q.add(1, a0)
    nopt = Kernel.max(1, pp.nopt)
    z0 = Q.new(1, nopt)
    stake! = Q.min(Q.coerce(stake), z0)
    pledge! = Q.min(Q.coerce(pledge), z0)

    # rewardℚ = pot ÷ (1+a0) * ( σ' + p'·a0·(σ' − p'·(z0−σ')÷z0)÷z0 )
    inner = Q.sub(stake!, Q.div(Q.mul(pledge!, Q.sub(z0, stake!)), z0))
    factor = Q.add(stake!, Q.div(Q.mul(Q.mul(pledge!, a0), inner), z0))
    Q.floor_pos(Q.mul(Q.div(Q.coerce(reward_pot), one_plus_a0), factor))
  end

  @doc """
  mkApparentPerformance (Rewards.lagda.md:232-248): blocks actually made over blocks expected
  for the pool's ACTIVE relative stake σa — `(n / (1 ⊔ N)) ÷₀ σa`. A rational (CAN exceed 1 for
  an over-performing pool); 0 when σa is 0 (the ÷₀).
  """
  def apparent_performance(stake, pool_blocks, total_blocks) do
    ratio = Q.new(pool_blocks, Kernel.max(1, total_blocks))
    Q.div_or_zero(ratio, Q.coerce(stake))
  end

  @doc """
  rewardOwners (Rewards.lagda.md:276-284): the pool operator's cut — the whole reward if it
  doesn't cover the declared cost, else cost + margin + the owners' stake-proportional share of
  the remainder. `owner_stake` and `stake` are RELATIVE (unit-interval rationals).
  """
  def reward_owners(rewards, pool_params, owner_stake, stake) do
    cost = pool_params.cost

    if rewards <= cost do
      rewards
    else
      margin = Q.coerce(pool_params.margin)
      ratio = Q.div_or_zero(Q.coerce(owner_stake), Q.coerce(stake))
      share = Q.add(margin, Q.mul(Q.sub(1, margin), ratio))
      cost + Q.floor_pos(Q.mul(Q.from_int(rewards - cost), share))
    end
  end

  @doc """
  rewardMember (Rewards.lagda.md:286-295): one delegator's cut — 0 if the pool reward doesn't
  cover cost, else the member's stake-proportional share of the post-cost remainder after the
  operator's margin.
  """
  def reward_member(rewards, pool_params, member_stake, stake) do
    cost = pool_params.cost

    if rewards <= cost do
      0
    else
      margin = Q.coerce(pool_params.margin)
      ratio = Q.div_or_zero(Q.coerce(member_stake), Q.coerce(stake))
      Q.floor_pos(Q.mul(Q.from_int(rewards - cost), Q.mul(Q.sub(1, margin), ratio)))
    end
  end

  @doc """
  rewardOnePool (Rewards.lagda.md:336-366): distribute one pool's reward among its delegators
  (by credential) and its operator (under the registration cert's reward-account credential).
  `n`/`total_blocks` are this pool's / the epoch's block counts, `stake_distr` is the stake
  filtered to THIS pool's delegators, `sigma`/`sigma_a` its total/active relative stake, `tot`
  the circulation. The pool forfeits everything (maxP = 0) if the owners' actual stake doesn't
  meet the pledge. Returns `credential => coin`.
  """
  def reward_one_pool(pp, reward_pot, n, total_blocks, params, stake_distr, sigma, sigma_a, tot) do
    # mkRelativeStake = clamp (coin /₀ tot)
    rel = fn coin -> Q.clamp_unit(Q.div_or_zero(Q.coerce(coin), Q.coerce(tot))) end
    owners = MapSet.new(params.owners, &{:key, &1})

    owner_stake =
      stake_distr
      |> Enum.filter(fn {c, _} -> MapSet.member?(owners, c) end)
      |> Enum.reduce(0, fn {_, v}, acc -> acc + v end)

    max_p =
      if params.pledge <= owner_stake,
        do: max_pool(pp, reward_pot, sigma, rel.(params.pledge)),
        else: 0

    pool_reward = Q.floor_pos(Q.mul(apparent_performance(sigma_a, n, total_blocks), max_p))

    member_rewards =
      for {c, coin} <- stake_distr, not MapSet.member?(owners, c), into: %{} do
        {c, reward_member(pool_reward, params, rel.(coin), sigma)}
      end

    owners_reward = reward_owners(pool_reward, params, rel.(owner_stake), sigma)

    case Address.stake_credential(params.reward_account) do
      # A reward address that doesn't parse to a credential (malformed cert) — the network
      # wouldn't have accepted the registration, so this is defensive: keep the members' cut,
      # drop (don't crash on) the operator's.
      nil -> member_rewards
      cred -> union_plus(member_rewards, %{cred => owners_reward})
    end
  end

  @doc """
  poolStake (Rewards.lagda.md:383-385): the stake distribution filtered to the credentials that
  delegate to pool `hk` — `stake ∣ dom (delegs ∣^ ❴ hk ❵)`.
  """
  def pool_stake(hk, delegs, stake) do
    Map.filter(stake, fn {c, _} -> Map.get(delegs, c) == hk end)
  end

  @doc """
  reward (Rewards.lagda.md:453-470): apply rewardOnePool to every registered pool that made at
  least one block (a pool absent from `blocks` is skipped — `lookupᵐ? blocks hk`), and sum the
  per-pool results by credential (the spec's aggregateBy). σ is relative to `total` (circulation),
  σa to the ACTIVE stake (Σ of the snapshot's stake map). Returns `credential => coin`.
  """
  def reward(pp, blocks, reward_pot, pools, stake, delegs, total) do
    active = stake |> Map.values() |> Enum.sum()
    total_blocks = blocks |> Map.values() |> Enum.sum()

    pools
    |> Enum.flat_map(fn
      # A registration that decoded to :malformed carries no pledge/cost — the network would
      # have rejected it; skip defensively rather than crash the epoch fold.
      {_hk, %{malformed: _}} ->
        []

      {hk, params} ->
        case Map.get(blocks, hk) do
          nil ->
            []

          n ->
            s = pool_stake(hk, delegs, stake)
            s_sum = s |> Map.values() |> Enum.sum()
            sigma = Q.clamp_unit(Q.div_or_zero(Q.coerce(s_sum), Q.coerce(total)))
            sigma_a = Q.clamp_unit(Q.div_or_zero(Q.coerce(s_sum), Q.coerce(active)))
            [reward_one_pool(pp, reward_pot, n, total_blocks, params, s, sigma, sigma_a, total)]
        end
    end)
    |> Enum.reduce(%{}, &union_plus/2)
  end

  @doc "The spec's ∪⁺ — merge two coin maps, summing where keys collide."
  def union_plus(a, b), do: Map.merge(a, b, fn _k, x, y -> x + y end)
end
