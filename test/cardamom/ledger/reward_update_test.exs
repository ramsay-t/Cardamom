defmodule Cardamom.Ledger.RewardUpdateTest do
  @moduledoc """
  createRUpd (Epoch.lagda.md:217-277) + applyRUpd-as-ops (Epoch.lagda.md:383-404), against the
  same independent Python-Fraction oracle as rewards_test.exs.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.RewardUpdate

  defp h(n), do: <<n::224>>
  defp k(n), do: {:key, h(n)}
  defp reward_addr(n), do: <<0xE0, h(n)::binary>>

  # The oracle scenario: slots=100, activeSlotsCoeff=1/20 (5 expected blocks), 4 blocks made
  # → η=4/5; reserves=10000, feeSS=100, ρ=3/1000, τ=1/5, total supply 11000 → circulation 1000.
  defp es do
    %{
      pparams: %{a0: {3, 10}, nopt: 3, rho: {3, 1000}, tau: {1, 5}, active_slots_coeff: {1, 20}},
      reserves: 10_000,
      fee_ss: 100,
      go: %{
        stake: %{k(101) => 100, k(1) => 200, k(2) => 100, k(102) => 50, k(3) => 300},
        delegations: %{k(101) => "P1", k(1) => "P1", k(2) => "P1", k(102) => "P2", k(3) => "P2"},
        pools: %{
          "P1" => %{pledge: 100, cost: 10, margin: {1, 10}, owners: [h(101)], reward_account: reward_addr(201)},
          "P2" => %{pledge: 50, cost: 500, margin: {1, 2}, owners: [h(102)], reward_account: reward_addr(202)}
        }
      }
    }
  end

  defp blocks, do: %{"P1" => 3, "P2" => 1}

  test "createRUpd matches the oracle: Δt/Δr/Δf and the full rs" do
    # oracle: dr1=floor((4/5)·(3/1000)·10000)=24, pot=124, dt=floor(124/5)=24, R=100,
    #         Σrs=49 → dr = -24 + (100-49) = 27, df = -100.
    ru = RewardUpdate.create(100, blocks(), es(), 11_000)

    assert %{dt: 24, dr: 27, df: -100} = ru
    assert ru.rs == %{k(1) => 12, k(2) => 6, k(3) => 0, k(201) => 18, k(202) => 13}
  end

  test "flow conservation holds: Δt + Δr + Δf + Σrs = 0 (Rewards.lagda.md:496)" do
    ru = RewardUpdate.create(100, blocks(), es(), 11_000)
    rs_sum = ru.rs |> Map.values() |> Enum.sum()
    assert ru.dt + ru.dr + ru.df + rs_sum == 0
  end

  test "MC/DC: no blocks at all → η = 0 → no reserve draw; pot is fees only" do
    # dr1 = 0, pot = 100, dt = 20, R = 80; no pool made a block so rs = %{} and dr2 = R.
    ru = RewardUpdate.create(100, %{}, es(), 11_000)
    assert %{dt: 20, dr: 80, df: -100, rs: rs} = ru
    assert rs == %{}
  end

  test "MC/DC: η ≥ 1 is capped at 1 (1 ⊓ η) — over-production draws no extra reserves" do
    # 10 blocks vs 5 expected → η = 2, capped: dr1 = floor(1·(3/1000)·10000) = 30.
    over = Map.put(blocks(), "P1", 9)
    ru = RewardUpdate.create(100, over, es(), 11_000)
    capped = RewardUpdate.create(100, %{"P1" => 4, "P2" => 1}, es(), 11_000)
    # both have blocksMade ≥ 5 → same η cap → same reserve draw (Δf is fixed; dt from same pot)
    assert ru.dt == capped.dt
    assert ru.df == capped.df
  end

  describe "apply_ops (applyRUpd, Epoch.lagda.md:383-404)" do
    test "registered rewards land in accounts; deregistered fold into the treasury" do
      ru = %{dt: 24, dr: 27, df: -100, rs: %{k(1) => 12, k(2) => 6, k(201) => 31}}
      # k(2)'s account has been deregistered since the go snapshot.
      registered = %{k(1) => 1000, k(201) => 0}

      ops = RewardUpdate.apply_ops(ru, registered)

      assert {:add, :pot, :treasury, 30} in ops, "Δt 24 + unregistered 6"
      assert {:add, :pot, :reserves, 27} in ops
      assert {:add, :fees, :pot, -100} in ops
      assert {:add, :reward, k(1), 12} in ops
      assert {:add, :reward, k(201), 31} in ops
      # the deregistered credential gets NO reward-account op — its coin went to the treasury
      refute Enum.any?(ops, &match?({:add, :reward, {:key, <<2::224>>}, _}, &1))
    end

    test "zero-coin reward entries produce no op (journal hygiene)" do
      ru = %{dt: 0, dr: 0, df: 0, rs: %{k(1) => 0}}
      ops = RewardUpdate.apply_ops(ru, %{k(1) => 5})
      refute Enum.any?(ops, &match?({:add, :reward, _, _}, &1))
    end
  end
end
