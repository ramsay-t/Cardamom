defmodule Cardamom.Ledger.EpochTransitionTest do
  @moduledoc """
  NEWEPOCH as invertible ops (Epoch.lagda.md:807-833): applyRUpd → SNAP (Rewards.lagda.md:836-840)
  → POOLREAP (PoolReap.lagda.md) → last_epoch. Pure state-machine tests over an injected ledger
  image, plus an apply-then-invert ROUND-TRIP through the real store (TEST_STRATEGY §4) proving a
  rollback across an epoch boundary restores the ledger byte-identically.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.{Delta, EpochTransition}

  defp h(n), do: <<n::224>>
  defp k(n), do: {:key, h(n)}
  defp reward_addr(n), do: <<0xE0, h(n)::binary>>

  # The oracle scenario, as the in-memory ledger image entering the boundary.
  defp state do
    %{
      last_epoch: 9,
      rewards: %{k(1) => 0, k(2) => 0, k(3) => 0, k(101) => 0, k(102) => 0, k(201) => 0, k(202) => 0},
      delegations: %{k(101) => "P1", k(1) => "P1", k(2) => "P1", k(102) => "P2", k(3) => "P2"},
      pools: %{"P1" => pool1(), "P2" => pool2()},
      retiring: %{},
      deposits: %{},
      treasury: 500,
      reserves: 10_000,
      fees: 130,
      snapshots: %{mark: snap(:mark), set: snap(:set), go: go_snapshot(), fee_ss: 100}
    }
  end

  defp pool1,
    do: %{pledge: 100, cost: 10, margin: {1, 10}, owners: [h(101)], reward_account: reward_addr(201)}

  defp pool2,
    do: %{pledge: 50, cost: 500, margin: {1, 2}, owners: [h(102)], reward_account: reward_addr(202)}

  defp go_snapshot do
    %{
      stake: %{k(101) => 100, k(1) => 200, k(2) => 100, k(102) => 50, k(3) => 300},
      delegations: %{k(101) => "P1", k(1) => "P1", k(2) => "P1", k(102) => "P2", k(3) => "P2"},
      pools: %{"P1" => pool1(), "P2" => pool2()}
    }
  end

  # Distinguishable placeholder snapshots for rotation checks.
  defp snap(label), do: %{stake: %{}, delegations: %{}, pools: %{}, label: label}

  defp deps do
    %{
      pparams: %{a0: {3, 10}, nopt: 3, rho: {3, 1000}, tau: {1, 5}, active_slots_coeff: {1, 20}},
      slots_per_epoch: 100,
      total_supply: 11_000,
      blocks_made: fn 8 -> %{"P1" => 3, "P2" => 1} end,
      utxo_by_cred: %{k(1) => 200, k(2) => 100, k(3) => 300, k(101) => 100, k(102) => 50}
    }
  end

  test "bootstrap (last_epoch nil): records the epoch, nothing else" do
    {ops, st} = EpochTransition.ops(%{state() | last_epoch: nil}, 7, deps())
    assert ops == [{:set, :epoch, :last_epoch, nil, 7}]
    assert st.last_epoch == 7
  end

  test "NEWEPOCH-Not-New: same epoch → identity" do
    assert {[], _} = EpochTransition.ops(state(), 9, deps())
  end

  test "NEWEPOCH-New: pays the oracle reward update into the state" do
    # oracle: dt=24 dr=27 df=-100, rs = M1:12 M2:6 M3:0 RA1:18 RA2:13 (all registered here)
    {_ops, st} = EpochTransition.ops(state(), 10, deps())

    assert st.treasury == 500 + 24
    assert st.reserves == 10_000 + 27
    assert st.fees == 130 - 100
    assert st.rewards[k(1)] == 12
    assert st.rewards[k(201)] == 18
    assert st.last_epoch == 10
  end

  test "SNAP rotation: go←set, set←mark, mark←fresh (post-RU stake), feeSS←fees pot" do
    {ops, st} = EpochTransition.ops(state(), 10, deps())

    assert st.snapshots.go.label == :set
    assert st.snapshots.set.label == :mark
    # feeSS captured BEFORE this block's own fees would accrue, AFTER Δf: 130 - 100
    assert st.snapshots.fee_ss == 30
    # the new mark sees the rewards JUST PAID (spec: EPOCH runs on eps' = applyRUpd ru eps):
    # M1 = utxo 200 + reward 12
    assert st.snapshots.mark.stake[k(1)] == 212

    # and the ops say the same
    assert {:set, :snapshot, :fee_ss, 100, 30} in ops
  end

  test "NEWEPOCH-No-Reward-Update: no go snapshot → SNAP still rotates, no pots move" do
    st0 = %{state() | snapshots: %{mark: snap(:mark), set: nil, go: nil, fee_ss: nil}}
    {ops, st} = EpochTransition.ops(st0, 10, deps())

    assert st.treasury == 500 and st.reserves == 10_000 and st.fees == 130
    refute Enum.any?(ops, &match?({:add, :pot, _, _}, &1))
    assert st.snapshots.set.label == :mark
    assert st.snapshots.go == nil
  end

  test "multi-boundary catch-up crosses each epoch once, in order" do
    # blocks_made will be asked for epochs 8 (entering 10) and 9 (entering 11).
    deps = %{deps() | blocks_made: fn e when e in [8, 9] -> %{"P1" => 3, "P2" => 1} end}
    {ops, st} = EpochTransition.ops(state(), 11, deps)

    assert st.last_epoch == 11
    assert Enum.filter(ops, &match?({:set, :epoch, :last_epoch, _, _}, &1)) ==
             [{:set, :epoch, :last_epoch, 9, 10}, {:set, :epoch, :last_epoch, 10, 11}]

    # after two rotations the original mark is now go
    assert st.snapshots.go.label == :mark
  end

  defp retiring_state do
    %{
      state()
      | retiring: %{"P2" => 10},
        deposits: %{{:pool, "P2"} => 500_000_000}
    }
  end

  describe "POOLREAP (PoolReap.lagda.md)" do
    test "retired pool: deposit refunds to its reward account; pool, retirement, deposit, delegations all drop" do
      {ops, st} = EpochTransition.ops(retiring_state(), 10, deps())

      # RA2 got its RU reward (13) AND the deposit refund
      assert st.rewards[k(202)] == 13 + 500_000_000
      refute Map.has_key?(st.pools, "P2")
      refute Map.has_key?(st.retiring, "P2")
      refute Map.has_key?(st.deposits, {:pool, "P2"})
      refute Enum.any?(st.delegations, fn {_c, p} -> p == "P2" end)

      assert {:del, :pool, "P2", pool2()} in ops
      assert {:del, :stake_deleg, k(3), "P2"} in ops
    end

    test "MC/DC: deregistered reward account → deposit goes to the TREASURY (unclaimed)" do
      st0 = %{retiring_state() | rewards: Map.delete(retiring_state().rewards, k(202))}
      {_ops, st} = EpochTransition.ops(st0, 10, deps())

      # treasury: 500 + Δt 24 + RU's unregistered RA2 reward 13 + unclaimed deposit
      assert st.treasury == 500 + 24 + 13 + 500_000_000
    end

    test "MC/DC: a pool retiring at a LATER epoch is untouched" do
      st0 = %{retiring_state() | retiring: %{"P2" => 11}}
      {_ops, st} = EpochTransition.ops(st0, 10, deps())

      assert Map.has_key?(st.pools, "P2")
      assert st.retiring == %{"P2" => 11}
    end
  end

  test "ROUND-TRIP: apply the boundary ops to the store, invert them, state is identical (TEST_STRATEGY §4)" do
    # Materialise the pre-state into the real ledger-state store.
    st = retiring_state()
    ChainStore.ledger_set(:epoch, :last_epoch, st.last_epoch)
    ChainStore.ledger_set(:pot, :treasury, st.treasury)
    ChainStore.ledger_set(:pot, :reserves, st.reserves)
    ChainStore.ledger_set(:fees, :pot, st.fees)
    Enum.each(st.rewards, fn {c, v} -> ChainStore.ledger_set(:reward, c, v) end)
    Enum.each(st.delegations, fn {c, p} -> ChainStore.ledger_set(:stake_deleg, c, p) end)
    Enum.each(st.pools, fn {p, params} -> ChainStore.ledger_set(:pool, p, params) end)
    Enum.each(st.retiring, fn {p, e} -> ChainStore.ledger_set(:pool_retiring, p, e) end)
    Enum.each(st.deposits, fn {kk, v} -> ChainStore.ledger_set(:deposit, kk, v) end)
    Enum.each(st.snapshots, fn {kk, v} -> if v, do: ChainStore.ledger_set(:snapshot, kk, v) end)

    before = dump_ledger()

    {ops, _} = EpochTransition.ops(st, 10, deps())
    Delta.apply_forward(ops)
    assert dump_ledger() != before, "the transition must actually change state"
    assert ChainStore.ledger_read(:epoch, :last_epoch) == 10

    Delta.apply_inverse(ops)
    assert dump_ledger() == before, "rollback across the boundary must restore the ledger exactly"
  end

  defp dump_ledger do
    for dom <- ~w(reward stake_deleg pool pool_retiring deposit pot fees snapshot epoch)a,
        into: %{},
        do: {dom, ChainStore.ledger_domain(dom)}
  end
end
