defmodule Cardamom.Ledger.EpochTransition do
  @moduledoc """
  NEWEPOCH for a follower (Epoch.lagda.md:807-833), rendered as INVERTIBLE Delta ops so that a
  rollback across an epoch boundary undoes the whole transition (rewards paid, pots moved,
  snapshots rotated, pools reaped) exactly like any other block delta.

  Per crossed boundary, in spec order:

    1. applyRUpd            — pay the pending reward update (NEWEPOCH-New; skipped when no GO
                              snapshot exists yet — NEWEPOCH-No-Reward-Update)
    2. SNAP                 — rotate mark/set/go, capture the new stake distribution and feeSS
                              (Rewards.lagda.md:836-840). Runs on the POST-applyRUpd state: the
                              spec's EPOCH takes eps' = applyRUpd ru eps, so the new mark stake
                              includes the rewards just paid.
    3. POOLREAP             — retire pools whose retirement epoch arrived: refund deposits to
                              their reward accounts (or the treasury if deregistered), drop their
                              delegations (PoolReap.lagda.md POOLREAP rule)
    4. set :epoch/:last_epoch

  We compute the reward update LAZILY at the boundary rather than mid-epoch (the spec's RUPD
  fires after RandomnessStabilisationWindow): every input it reads — the GO snapshot, reserves,
  feeSS, pparams — is constant between boundaries, so the result is identical; a follower has no
  need for the early availability the window exists to provide (it exists so block producers can
  agree on the update before applying it).

  The transition works over an IN-MEMORY image of the ledger domains (`state`, loaded once by the
  caller) and threads its own changes through, so multi-boundary catch-up and the RU-before-SNAP
  ordering read the right intermediate values; the store is only touched when the returned ops
  are journalled + applied by the caller (BlockHandler → ChainStore.ledger_apply_block).

  NOT here (out of scope, deliberately): the EPOCH rule's governance half — RATIFY/enactment,
  gov-action expiry + deposit refunds, DRep expiry bump, CC hot-key pruning (Epoch.lagda.md
  EPOCH rule). We don't track gov actions yet; when we do, it slots in between SNAP and the
  last_epoch bump.
  """

  require Logger

  alias Cardamom.Ledger.{Address, RewardUpdate, Stake}

  @doc """
  The ops for advancing the ledger from `state.last_epoch` to `target_epoch` (one entry per
  crossed boundary, concatenated). `state` is the in-memory ledger image (see
  `ChainStore.epoch_ledger_state/0`):

      %{last_epoch:, rewards:, delegations:, pools:, retiring:, deposits:,
        treasury:, reserves:, fees:, snapshots: %{mark:, set:, go:, fee_ss:}}

  `deps` supplies what the transition can't know:

      %{pparams: %{a0: nopt: rho: tau: active_slots_coeff:},
        slots_per_epoch:, total_supply:,
        blocks_made: (epoch -> %{pool_keyhash => count}),
        utxo_by_cred: %{credential => coin}}

  Returns `{ops, state'}`. `last_epoch: nil` (first block ever) just records the epoch — there
  is no prior epoch to close.
  """
  def ops(%{last_epoch: nil} = state, target_epoch, _deps) do
    {[{:set, :epoch, :last_epoch, nil, target_epoch}], %{state | last_epoch: target_epoch}}
  end

  def ops(%{last_epoch: last} = state, target_epoch, _deps) when target_epoch <= last do
    # NEWEPOCH-Not-New: same epoch, identity. (A target BELOW last_epoch cannot happen on the
    # forward path — rollback rewinds via the journal, not through here.)
    {[], state}
  end

  def ops(%{last_epoch: last} = state, target_epoch, deps) do
    Enum.reduce((last + 1)..target_epoch, {[], state}, fn e, {ops_acc, st} ->
      {ops, st} = one_boundary(e, st, deps)
      {ops_acc ++ ops, st}
    end)
  end

  # One NEWEPOCH: applyRUpd → SNAP → POOLREAP → last_epoch.
  defp one_boundary(e, st, deps) do
    {ru_ops, st} = apply_reward_update(e, st, deps)
    {snap_ops, st} = snap(st, deps)
    {reap_ops, st} = pool_reap(e, st)
    epoch_op = {:set, :epoch, :last_epoch, st.last_epoch, e}

    {ru_ops ++ snap_ops ++ reap_ops ++ [epoch_op], %{st | last_epoch: e}}
  end

  # --- 1. applyRUpd (NEWEPOCH-New / -No-Reward-Update) ---

  # No GO snapshot yet (fewer than three boundaries since genesis): nothing to pay.
  defp apply_reward_update(_e, %{snapshots: %{go: nil}} = st, _deps), do: {[], st}

  defp apply_reward_update(e, st, deps) do
    # The update entering epoch e rewards the blocks of epoch e-2 (produced under the leader
    # schedule of the then-"set" snapshot, which is our current "go").
    blocks = deps.blocks_made.(e - 2)

    es = %{
      pparams: deps.pparams,
      reserves: st.reserves,
      fee_ss: st.snapshots.fee_ss || 0,
      go: st.snapshots.go
    }

    ru = RewardUpdate.create(deps.slots_per_epoch, blocks, es, deps.total_supply)
    ops = RewardUpdate.apply_ops(ru, st.rewards)

    if st.reserves + ru.dr < 0 or st.fees + ru.df < 0 do
      # posPart in applyRUpd would clamp here; correct accounting never reaches it, so this is a
      # divergence signal (our derived state drifted), not a condition to hide.
      Logger.warning("epoch #{e}: reward update would drive a pot negative — divergence: #{inspect(Map.delete(ru, :rs))}")
    end

    st = %{
      st
      | rewards: pay_rewards(st.rewards, ru.rs),
        treasury: st.treasury + ru.dt + unregistered_sum(ru.rs, st.rewards),
        reserves: st.reserves + ru.dr,
        fees: st.fees + ru.df
    }

    {ops, st}
  end

  defp pay_rewards(rewards, rs) do
    rs
    |> Enum.filter(fn {cred, _} -> Map.has_key?(rewards, cred) end)
    |> Enum.reduce(rewards, fn {cred, coin}, acc -> Map.update(acc, cred, coin, &(&1 + coin)) end)
  end

  defp unregistered_sum(rs, rewards) do
    rs
    |> Enum.reject(fn {cred, _} -> Map.has_key?(rewards, cred) end)
    |> Enum.reduce(0, fn {_, coin}, acc -> acc + coin end)
  end

  # --- 2. SNAP (Rewards.lagda.md:836-840) ---

  defp snap(st, deps) do
    %{mark: mark, set: set, go: go, fee_ss: fee_ss} = st.snapshots

    new_mark = %{
      stake: Stake.distribution(deps.utxo_by_cred, st.delegations, st.rewards, st.pools),
      delegations: st.delegations,
      pools: st.pools
    }

    ops = [
      {:set, :snapshot, :go, go, set},
      {:set, :snapshot, :set, set, mark},
      {:set, :snapshot, :mark, mark, new_mark},
      {:set, :snapshot, :fee_ss, fee_ss, st.fees}
    ]

    {ops, %{st | snapshots: %{mark: new_mark, set: mark, go: set, fee_ss: st.fees}}}
  end

  # --- 3. POOLREAP (PoolReap.lagda.md) ---

  defp pool_reap(e, st) do
    retired = for {pool, ^e} <- st.retiring, do: pool

    {ops, st} =
      Enum.reduce(retired, {[], st}, fn pool, {ops_acc, acc} ->
        params = Map.get(acc.pools, pool)
        deposit = Map.get(acc.deposits, {:pool, pool}) || 0

        {refund_ops, acc} = reap_refund(deposit, params, acc)

        removal_ops =
          [{:del, :pool, pool, params}, {:del, :pool_retiring, pool, e}] ++
            if(Map.has_key?(acc.deposits, {:pool, pool}),
              do: [{:del, :deposit, {:pool, pool}, deposit}],
              else: []
            ) ++
            for {cred, ^pool} <- acc.delegations, do: {:del, :stake_deleg, cred, pool}

        acc = %{
          acc
          | pools: Map.delete(acc.pools, pool),
            retiring: Map.delete(acc.retiring, pool),
            deposits: Map.delete(acc.deposits, {:pool, pool}),
            delegations: Map.reject(acc.delegations, fn {_c, p} -> p == pool end)
        }

        {ops_acc ++ refund_ops ++ removal_ops, acc}
      end)

    {ops, st}
  end

  # The deposit refund: to the pool's reward account if that credential still has a registered
  # reward account (refunds = rewardAcnts' ∣ dom rewards), else to the treasury (unclaimed).
  defp reap_refund(0, _params, st), do: {[], st}

  defp reap_refund(deposit, params, st) do
    cred = params && Address.stake_credential(params.reward_account)

    if cred && Map.has_key?(st.rewards, cred) do
      {[{:add, :reward, cred, deposit}],
       %{st | rewards: Map.update(st.rewards, cred, deposit, &(&1 + deposit))}}
    else
      {[{:add, :pot, :treasury, deposit}], %{st | treasury: st.treasury + deposit}}
    end
  end

  @doc """
  Convenience: the per-pool ACTIVE stake of a snapshot — calculatePoolDelegatedStake
  (Epoch.lagda.md:421-435), for the leader-schedule / voting views.
  """
  def pool_delegated_stake(%{stake: stake, delegations: delegations, pools: pools}) do
    stake |> Stake.pool_stake(delegations) |> Map.take(Map.keys(pools))
  end

  @doc """
  The live `deps` for `ops/3`: params from `Cardamom.Ledger.Epoch.params/0`, BlocksMade walked
  back from `from_hash` (the block that triggered the boundary), and the UTxO-by-credential fold.
  Call ONLY when a boundary is actually being crossed — the UTxO fold is a full unspent scan.
  """
  def live_deps(from_hash) do
    p = Cardamom.Ledger.Epoch.params()

    %{
      pparams: %{a0: p.a0, nopt: p.nopt, rho: p.rho, tau: p.tau, active_slots_coeff: p.active_slots_coeff},
      slots_per_epoch: p.epoch_length,
      total_supply: p.max_lovelace_supply,
      blocks_made: fn epoch -> Cardamom.ChainStore.blocks_made(epoch, from_hash, p.epoch_length) end,
      utxo_by_cred: Stake.utxo_balance_by_credential()
    }
  end
end
