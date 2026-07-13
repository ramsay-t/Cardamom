defmodule Cardamom.Ledger.Stake do
  @moduledoc """
  The STAKE DISTRIBUTION SNAPSHOT — the spec's `stakeDistr` (Rewards.lagda.md:635-652) and
  `Snapshot` record (:581-586): the per-credential ACTIVE stake, the delegation map, and the pool
  params, captured together at an epoch boundary (SNAP) as the input the reward calculation reads
  two epochs later.

  ACTIVE is load-bearing (spec `activeDelegs`/`activeRewards`/`activeStake`): a credential counts
  only if it (a) has a REGISTERED reward account (`dom rewards`), and (b) DELEGATES to an
  EXISTING pool (`∣^ dom pools`). Its stake is then

      utxoBalance(cred) + rewardAccountBalance(cred)

  — including ZERO (an active credential with no funds still appears; `mapWithKey` over
  `activeRewards`). A UTxO whose address has no staking part (enterprise/pointer/Byron), or whose
  credential is not active, contributes to NO stake — correct: only delegated stake earns.

  The UTxO fold is a full scan of the unspent-txo set (millions of rows at mainnet). Today we
  LOAD all (address, value) pairs and fold in memory — two small columns, fine at Preview scale;
  at mainnet scale this should become a `Repo.stream` fold inside a transaction. It runs at the
  epoch boundary (SNAP), not per block — cost amortised over an epoch.
  """

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Address

  @doc """
  A live `Snapshot` (Rewards.lagda.md:581-586): `%{stake:, delegations:, pools:}` — the active
  stake distribution plus the FULL delegation map and pool params as of now. Taken by SNAP at
  each epoch boundary.
  """
  def snapshot do
    delegations = ChainStore.stake_delegations()
    pools = ChainStore.ledger_domain(:pool)
    rewards = ChainStore.reward_balances()

    %{
      stake: distribution(utxo_balance_by_credential(), delegations, rewards, pools),
      delegations: delegations,
      pools: pools
    }
  end

  @doc """
  stakeDistr's `activeStake` (Rewards.lagda.md:635-652), PURE: for every credential with a
  registered reward account that delegates to an existing pool, `utxoBalance + rewardBalance`.
  Zero-stake active credentials are present (with 0); inactive credentials are absent no matter
  how much UTxO value their addresses hold.
  """
  def distribution(utxo_by_cred, delegations, rewards, pools) do
    # activeDelegs = (stakeDelegs ∣ dom rewards) ∣^ dom pools
    active_delegs =
      Map.filter(delegations, fn {cred, pool} ->
        Map.has_key?(rewards, cred) and Map.has_key?(pools, pool)
      end)

    # activeStake = mapWithKey (λ c bal → utxoBalance c + bal) (rewards ∣ dom activeDelegs)
    for {cred, _pool} <- active_delegs, into: %{} do
      {cred, Map.get(utxo_by_cred, cred, 0) + (Map.get(rewards, cred) || 0)}
    end
  end

  @doc """
  Per-POOL delegated stake — `calculatePoolDelegatedStake` (Epoch.lagda.md:421-435): aggregate a
  stake distribution by the pool each credential delegates to. A credential with stake but no
  delegation contributes to no pool.
  """
  def pool_stake(stake, delegations) do
    Enum.reduce(stake, %{}, fn {cred, amount}, acc ->
      case Map.get(delegations, cred) do
        nil -> acc
        pool -> Map.update(acc, pool, amount, &(&1 + amount))
      end
    end)
  end

  @doc """
  The UTxO half of the stake distribution: total unspent value per staking credential, folded
  from every unspent txo's address (`utxoBalance`, Rewards.lagda.md:641-642). Addresses with no
  staking part fall out here (they map to no credential).
  """
  def utxo_balance_by_credential do
    ChainStore.unspent_stake_rows()
    |> Enum.reduce(%{}, fn {address, value}, acc ->
      case Address.stake_credential(address) do
        nil -> acc
        cred -> Map.update(acc, cred, value || 0, &(&1 + (value || 0)))
      end
    end)
  end
end
