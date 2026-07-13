defmodule Cardamom.Ledger.AddressTest do
  @moduledoc """
  Shelley address staking-credential parsing (CIP-19). Real-data test: a real block-16 base address
  yields a 28-byte stake KEY credential; a real enterprise address yields nil. Synthetic tests
  cover the address-type clauses the fixtures don't exercise (script-stake, reward address,
  pointer, malformed) — MC/DC on the type nibble.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.{Address, Conway.Tx}
  import Bitwise

  defp block(n) do
    Path.join([__DIR__, "..", "..", "fixtures", "blocks", "block-#{n}.hex"])
    |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
  end

  test "REAL: block 16's base address (57B, type 0) → a 28-byte stake KEY credential" do
    {:ok, txs} = Tx.txs_in(block(16))
    addrs = txs |> Enum.flat_map(& &1.outputs) |> Enum.map(& &1.address) |> Enum.filter(&is_binary/1)

    base = Enum.find(addrs, fn a -> byte_size(a) == 57 and :binary.first(a) >>> 4 == 0 end)
    assert base, "block 16 has a base (payment+stake) address"
    assert {:key, stake} = Address.stake_credential(base)
    assert byte_size(stake) == 28
  end

  test "REAL: block 16's enterprise address (29B, type 6) → nil (no staking part)" do
    {:ok, txs} = Tx.txs_in(block(16))
    addrs = txs |> Enum.flat_map(& &1.outputs) |> Enum.map(& &1.address) |> Enum.filter(&is_binary/1)
    ent = Enum.find(addrs, fn a -> byte_size(a) == 29 and :binary.first(a) >>> 4 == 6 end)
    assert ent
    assert Address.stake_credential(ent) == nil
  end

  # ---- MC/DC on the address type nibble (synthetic, CIP-19 shapes) ----

  defp base_addr(type, payment, stake), do: <<type <<< 4, payment::binary-size(28), stake::binary-size(28)>>
  defp reward_addr(type, stake), do: <<type <<< 4, stake::binary-size(28)>>

  test "base type 0 (key/key) and 1 (script-pay/key) → stake KEY" do
    assert {:key, _} = Address.stake_credential(base_addr(0, <<1::224>>, <<2::224>>))
    assert {:key, _} = Address.stake_credential(base_addr(1, <<1::224>>, <<2::224>>))
  end

  test "base type 2 and 3 → stake SCRIPT" do
    assert {:script, _} = Address.stake_credential(base_addr(2, <<1::224>>, <<2::224>>))
    assert {:script, _} = Address.stake_credential(base_addr(3, <<1::224>>, <<2::224>>))
  end

  test "reward address type 14 → key, 15 → script" do
    assert {:key, <<9::224>>} = Address.stake_credential(reward_addr(14, <<9::224>>))
    assert {:script, <<9::224>>} = Address.stake_credential(reward_addr(15, <<9::224>>))
  end

  test "enterprise (6/7) and pointer (4/5) → nil (no resolvable staking credential)" do
    assert Address.stake_credential(<<6 <<< 4, 0::224>>) == nil
    assert Address.stake_credential(<<4 <<< 4, 0::224, 1, 2, 3>>) == nil
  end

  test "malformed / empty / non-binary → nil, never crashes" do
    assert Address.stake_credential(<<>>) == nil
    assert Address.stake_credential(<<0>>) == nil
    # base type 0 header but a too-short payload (not 28+28) → nil (inner case fallback)
    assert Address.stake_credential(<<0::4, 0::4, 1, 2>>) == nil
    # reward type 14 header but a too-short payload (not 28) → nil (the OTHER inner case fallback)
    assert Address.stake_credential(<<14 <<< 4, 1, 2, 3>>) == nil
    assert Address.stake_credential(:not_bytes) == nil
  end
end
