defmodule Cardamom.Ledger.RewardsTest do
  @moduledoc """
  The reward calculation against an INDEPENDENT oracle: every expected value below was computed
  by a Python-Fraction transcription of the same Agda spec functions (exact rationals), so the
  Elixir implementation is checked against an independently-derived computation, not itself.
  Spec: Rewards.lagda.md (function names + line ranges cited per test).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Rewards
  alias Cardamom.Ledger.Rational, as: Q

  # 28-byte key hashes / credentials for the scenario (O=owner, M=member, RA=reward account).
  defp h(n), do: <<n::224>>
  defp k(n), do: {:key, h(n)}
  # A type-14 (stake-key) reward address on network 0: header 0xE0 || stake key hash.
  defp reward_addr(n), do: <<0xE0, h(n)::binary>>

  # pp for the shared scenario: a0 = 3/10, nopt = 3 (z0 = 1/3, so saturation caps bind early).
  @pp %{a0: {3, 10}, nopt: 3}

  defp pool1,
    do: %{pledge: 100, cost: 10, margin: {1, 10}, owners: [h(101)], reward_account: reward_addr(201)}

  defp pool2,
    do: %{pledge: 50, cost: 500, margin: {1, 2}, owners: [h(102)], reward_account: reward_addr(202)}

  # stake: O1 100, M1 200, M2 100 → P1; O2 50, M3 300 → P2. active = 750.
  defp stake,
    do: %{k(101) => 100, k(1) => 200, k(2) => 100, k(102) => 50, k(3) => 300}

  defp delegs,
    do: %{k(101) => "P1", k(1) => "P1", k(2) => "P1", k(102) => "P2", k(3) => "P2"}

  describe "max_pool (Rewards.lagda.md:177-217)" do
    test "basic: mainnet-like params, unsaturated pool" do
      # oracle mp_basic: a0=3/10 nopt=150 pot=1_000_000 σ=1/100 pledge=1/1000
      assert Rewards.max_pool(%{a0: {3, 10}, nopt: 150}, 1_000_000, Q.new(1, 100), Q.new(1, 1000)) ==
               5358
    end

    test "σ above z0 is capped at saturation (stake' = z0)" do
      # oracle mp_satcap: nopt=3 → z0=1/3; σ=1/2 capped
      assert Rewards.max_pool(@pp, 1000, Q.new(1, 2), Q.new(1, 10)) == 279
    end

    test "MC/DC: negative a0 is floored at 0 (0 ⊔ a0) — reward reduces to pot·σ'" do
      # oracle mp_a0neg
      assert Rewards.max_pool(%{a0: {-1, 2}, nopt: 3}, 1000, Q.new(1, 10), Q.new(1, 100)) == 100
    end

    test "MC/DC: nopt 0 is floored at 1 (1 ⊔ nopt) — z0 = 1" do
      # oracle mp_nopt0
      assert Rewards.max_pool(%{a0: {3, 10}, nopt: 0}, 1000, Q.new(1, 10), Q.new(1, 100)) == 77
    end
  end

  describe "apparent_performance (Rewards.lagda.md:232-248)" do
    test "÷₀: zero active stake → 0, not a crash" do
      assert Rewards.apparent_performance(Q.new(0, 1), 3, 4) == Q.from_int(0)
    end

    test "MC/DC: zero total blocks hits the 1 ⊔ N floor" do
      # oracle ap_zero_total: (3/1) ÷ (1/2) = 6
      assert Rewards.apparent_performance(Q.new(1, 2), 3, 0) == Q.from_int(6)
    end

    test "can exceed 1 for an over-performing pool" do
      # oracle ap_basic: (3/4) ÷ (8/15) = 45/32
      assert Rewards.apparent_performance(Q.new(8, 15), 3, 4) == Q.new(45, 32)
    end
  end

  describe "reward_owners / reward_member (Rewards.lagda.md:276-295)" do
    test "rewards ≤ cost: owners take everything, members take nothing (both branches)" do
      # oracle ro_cost_floor / rm_cost_floor: rewards 9 < cost 10
      assert Rewards.reward_owners(9, pool1(), Q.new(1, 4), Q.new(2, 5)) == 9
      assert Rewards.reward_member(9, pool1(), Q.new(1, 4), Q.new(2, 5)) == 0
    end

    test "÷₀: zero pool stake — owners still get cost + margin share" do
      # oracle ro_zero_sigma: 10 + floor(90 · (1/10 + 9/10·0)) = 19
      assert Rewards.reward_owners(100, pool1(), Q.new(1, 4), Q.new(0, 1)) == 19
    end
  end

  describe "reward (Rewards.lagda.md:453-470) — the full scenario" do
    test "matches the oracle distribution exactly" do
      # oracle: pot=100, circulation=1000, blocks P1:3 P2:1.
      # P2's pool reward (13) is below its cost (500) → M3 gets 0, RA2 takes all 13.
      rs =
        Rewards.reward(
          @pp,
          %{"P1" => 3, "P2" => 1},
          100,
          %{"P1" => pool1(), "P2" => pool2()},
          stake(),
          delegs(),
          1000
        )

      assert rs == %{
               k(1) => 12,
               k(2) => 6,
               k(3) => 0,
               k(201) => 18,
               k(202) => 13
             }
    end

    test "aggregateBy: two pools paying the SAME reward-account credential sum into one entry" do
      # oracle rs2: P2 redirected to RA1 → RA1 = 18 + 13 = 31
      rs =
        Rewards.reward(
          @pp,
          %{"P1" => 3, "P2" => 1},
          100,
          %{"P1" => pool1(), "P2" => %{pool2() | reward_account: reward_addr(201)}},
          stake(),
          delegs(),
          1000
        )

      assert rs[k(201)] == 31
      refute Map.has_key?(rs, k(202))
    end

    test "MC/DC: a pool with NO blocks is skipped entirely (lookupᵐ? blocks hk)" do
      rs =
        Rewards.reward(@pp, %{"P1" => 3}, 100, %{"P1" => pool1(), "P2" => pool2()}, stake(), delegs(), 1000)

      refute Map.has_key?(rs, k(202))
      refute Map.has_key?(rs, k(3))
    end

    test "MC/DC: pledge not met → maxP = 0 → every payout from that pool is 0" do
      # Owners of P1 hold 100; raise pledge above it.
      broke = %{pool1() | pledge: 101}

      rs = Rewards.reward(@pp, %{"P1" => 3}, 100, %{"P1" => broke}, stake(), delegs(), 1000)

      # pool_reward = 0 ≤ cost → members 0, owners get the whole 0.
      assert rs == %{k(1) => 0, k(2) => 0, k(201) => 0}
    end

    test "MC/DC: malformed pool registration is skipped, not crashed on" do
      rs =
        Rewards.reward(
          @pp,
          %{"P1" => 3, "PX" => 1},
          100,
          %{"P1" => pool1(), "PX" => %{malformed: [:junk]}},
          stake(),
          delegs(),
          1000
        )

      assert rs[k(201)] == 18
    end
  end

  describe "pool_stake (Rewards.lagda.md:383-385)" do
    test "filters the stake map to one pool's delegators" do
      assert Rewards.pool_stake("P2", delegs(), stake()) == %{k(102) => 50, k(3) => 300}
    end
  end
end
