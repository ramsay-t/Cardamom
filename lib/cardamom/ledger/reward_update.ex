defmodule Cardamom.Ledger.RewardUpdate do
  @moduledoc """
  The REWARD UPDATE — the net flow of Ada paid out at an epoch boundary
  (RewardUpdate record, Rewards.lagda.md:472-499; createRUpd, Epoch.lagda.md:217-277;
  applyRUpd, Epoch.lagda.md:383-404).

  `create/4` computes the four net flows for one boundary:

    Δt (treasury, ≥0)   Δr (reserves, usually <0)   Δf (fee pot, ≤0)   rs (per-credential rewards)

  from the monetary expansion ρ, the pool performance factor η = blocksMade ÷₀ (slotsPerEpoch ×
  activeSlotsCoeff), the treasury cut τ, and the full `Cardamom.Ledger.Rewards` distribution over
  the GO snapshot. Flow conservation (Δt + Δr + Δf + Σrs ≡ 0) is PROVEN in the spec; here it is
  asserted — a violation is a programming error, so `create/4` raises rather than returns garbage.

  `apply_ops/2` renders applyRUpd as INVERTIBLE Delta ops: rewards for still-registered
  credentials land in their reward accounts (`rs ∣ dom rewards`); rewards whose account was
  deregistered since the snapshot go to the TREASURY instead (`unregRU'`). The spec's posPart
  clamps never bind when the accounting is right, so `:add` ops (exactly invertible) are faithful;
  a pot that would go negative is a divergence to be caught by conformance, not silently clamped.
  """

  alias Cardamom.Ledger.Rewards
  alias Cardamom.Ledger.Rational, as: Q

  @doc """
  createRUpd (Epoch.lagda.md:217-277). Args:

    * `slots_per_epoch` — epoch length in slots
    * `blocks` — BlocksMade for the epoch being rewarded: `pool_keyhash => count`
    * `es` — the epoch state the calculation reads:
        `%{pparams: %{a0:, nopt:, rho:, tau:, active_slots_coeff:}, reserves:, fee_ss:,
           go: %{stake:, delegations:, pools:}}` (go = the snapshot labelled "go")
    * `total` — total lovelace supply (maxLovelaceSupply)

  Returns `%{dt:, dr:, df:, rs:}` (integers + `credential => coin` map).
  """
  def create(slots_per_epoch, blocks, es, total) do
    pp = es.pparams
    reserves = es.reserves
    fee_ss = es.fee_ss
    %{stake: stake, delegations: delegs, pools: pools} = es.go

    blocks_made = blocks |> Map.values() |> Enum.sum()

    rho = Q.coerce(pp.rho)
    tau = Q.coerce(pp.tau)
    eta = Q.div_or_zero(Q.from_int(blocks_made), Q.mul(slots_per_epoch, Q.coerce(pp.active_slots_coeff)))

    dr1 = Q.floor(Q.mul(Q.mul(Q.min(1, eta), rho), reserves))
    reward_pot = fee_ss + dr1
    dt1 = Q.floor(Q.mul(reward_pot, tau))
    r = reward_pot - dt1
    circulation = total - reserves

    rs = Rewards.reward(pp, blocks, Kernel.max(r, 0), pools, stake, delegs, circulation)

    rs_sum = rs |> Map.values() |> Enum.sum()
    dr2 = r - rs_sum

    ru = %{dt: dt1, dr: -dr1 + dr2, df: -fee_ss, rs: rs}

    # flowConservation (Rewards.lagda.md:496) — proven in the spec, asserted here.
    if ru.dt + ru.dr + ru.df + rs_sum != 0 do
      raise "reward update violates flow conservation: #{inspect(Map.delete(ru, :rs))} Σrs=#{rs_sum}"
    end

    ru
  end

  @doc """
  applyRUpd (Epoch.lagda.md:383-404) as invertible Delta ops. `rewards` is the CURRENT
  reward-account map (`credential => balance`) — an rs entry whose credential is still registered
  is paid into its account; one whose account has since been deregistered is folded into the
  treasury alongside Δt (`unregRU'`).
  """
  def apply_ops(%{dt: dt, dr: dr, df: df, rs: rs}, rewards) do
    {reg, unreg} = Enum.split_with(rs, fn {cred, _} -> Map.has_key?(rewards, cred) end)
    unreg_sum = Enum.reduce(unreg, 0, fn {_, c}, acc -> acc + c end)

    pot_ops = [
      {:add, :pot, :treasury, dt + unreg_sum},
      {:add, :pot, :reserves, dr},
      {:add, :fees, :pot, df}
    ]

    # 0-coin adds are no-ops but the spec's ∪⁺ keeps them; drop for journal hygiene.
    reward_ops = for {cred, coin} <- reg, coin != 0, do: {:add, :reward, cred, coin}

    pot_ops ++ reward_ops
  end
end
