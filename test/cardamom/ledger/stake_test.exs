defmodule Cardamom.Ledger.StakeTest do
  @moduledoc """
  The stake-distribution SNAPSHOT — spec `stakeDistr` (Rewards.lagda.md:635-652). ACTIVE stake
  only: a credential counts iff it has a registered reward account AND delegates to an existing
  pool; its stake is utxoBalance + rewardBalance, INCLUDING zero. Uses real-shaped Shelley
  addresses so Address.stake_credential parses genuine layouts.
  """
  use Cardamom.DataCase, async: false
  import Bitwise

  alias Cardamom.{ChainStore, Ledger.Stake, Ledger.Address}
  alias Cardamom.Store.{Repo, Txo}

  # A base address (type 0): header || payment(28) || stake(28) — delegates to the stake credential.
  defp base_addr(stake_hash), do: <<0 <<< 4, 0::224, stake_hash::binary-size(28)>>
  # Enterprise (type 6): payment only, no staking part.
  defp ent_addr, do: <<6 <<< 4, 0::224>>

  defp seed_txo(txid, ix, address, value) do
    {:ok, _} = Repo.insert(%Txo{txid: txid, ix: ix, address: address, value: value})
  end

  # Make `cred` ACTIVE: registered reward account (balance) + delegation to a registered pool.
  defp activate(cred, pool, reward_balance \\ 0) do
    ChainStore.ledger_set(:reward, cred, reward_balance)
    ChainStore.ledger_set(:stake_deleg, cred, pool)
    ChainStore.ledger_set(:pool, pool, %{fake: :params})
  end

  test "active credential: unspent-txo value + reward balance; enterprise value counts nowhere" do
    sh = <<7::224>>
    cred = {:key, sh}
    seed_txo(<<1::256>>, 0, base_addr(sh), 1_000_000)
    seed_txo(<<2::256>>, 0, base_addr(sh), 2_500_000)
    seed_txo(<<3::256>>, 0, ent_addr(), 9_000_000)
    activate(cred, "poolX", 500_000)

    snap = Stake.snapshot()
    assert snap.stake[cred] == 4_000_000
    assert map_size(snap.stake) == 1, "enterprise value is staked to no credential"
  end

  test "MC/DC activeDelegs: NO registered reward account → excluded, however much UTxO it holds" do
    sh = <<8::224>>
    seed_txo(<<1::256>>, 0, base_addr(sh), 7_000_000)
    # delegates to a real pool but reward account never registered (only the other conjunct holds)
    ChainStore.ledger_set(:stake_deleg, {:key, sh}, "poolX")
    ChainStore.ledger_set(:pool, "poolX", %{fake: :params})

    assert Stake.snapshot().stake == %{}
  end

  test "MC/DC activeDelegs: delegation to a NON-EXISTENT pool → excluded" do
    sh = <<9::224>>
    cred = {:key, sh}
    seed_txo(<<1::256>>, 0, base_addr(sh), 7_000_000)
    ChainStore.ledger_set(:reward, cred, 0)
    ChainStore.ledger_set(:stake_deleg, cred, "ghost-pool")

    assert Stake.snapshot().stake == %{}
  end

  test "MC/DC activeDelegs: registered but NOT delegating → excluded" do
    sh = <<10::224>>
    cred = {:key, sh}
    seed_txo(<<1::256>>, 0, base_addr(sh), 7_000_000)
    ChainStore.ledger_set(:reward, cred, 100)

    assert Stake.snapshot().stake == %{}
  end

  test "an active credential with ZERO stake is PRESENT with 0 (mapWithKey over activeRewards)" do
    cred = {:key, <<11::224>>}
    activate(cred, "poolX", 0)

    assert Stake.snapshot().stake == %{cred => 0}
  end

  test "snapshot carries the FULL delegation map (not the active restriction) + pools" do
    active = {:key, <<12::224>>}
    inactive = {:key, <<13::224>>}
    activate(active, "poolX")
    # inactive: delegation without registration — still in the snapshot's delegation map
    ChainStore.ledger_set(:stake_deleg, inactive, "poolX")

    snap = Stake.snapshot()
    assert snap.delegations == %{active => "poolX", inactive => "poolX"}
    assert Map.keys(snap.pools) == ["poolX"]
  end

  test "pool_stake aggregates a stake distribution by delegation (Epoch.lagda.md:421-435)" do
    a = {:key, <<14::224>>}
    b = {:key, <<15::224>>}
    c = {:key, <<16::224>>}
    stake = %{a => 1_000_000, b => 4_000_000, c => 7_000_000}
    delegs = %{a => "poolX", b => "poolX"}

    assert Stake.pool_stake(stake, delegs) == %{"poolX" => 5_000_000}
  end

  test "sanity: the base address round-trips through the parser to the expected credential" do
    assert Address.stake_credential(base_addr(<<7::224>>)) == {:key, <<7::224>>}
  end
end
