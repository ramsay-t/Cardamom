defmodule Cardamom.Ledger.EpochTest do
  @moduledoc """
  Epoch arithmetic — the clock the reward engine fires on. Uses Preview's real epochLength (86400,
  from shelley-genesis, never hardcoded mainnet). MC/DC on boundaries_crossed: nil-prev clause,
  same-epoch clause, one-boundary clause, and the (defensive) multi-boundary clause.
  """
  use ExUnit.Case, async: true
  alias Cardamom.Ledger.Epoch

  @len 86_400

  test "of/2: slot → epoch (integer division by epoch length)" do
    assert Epoch.of(0, @len) == 0
    assert Epoch.of(86_399, @len) == 0
    assert Epoch.of(86_400, @len) == 1
    assert Epoch.of(200_000, @len) == 2
  end

  test "first_slot/2 is the epoch's lower boundary" do
    assert Epoch.first_slot(0, @len) == 0
    assert Epoch.first_slot(1, @len) == 86_400
    assert Epoch.first_slot(3, @len) == 259_200
  end

  test "boundaries_crossed: first block seen (nil prev) enters its epoch" do
    assert Epoch.boundaries_crossed(nil, 100, @len) == [0]
    assert Epoch.boundaries_crossed(nil, 90_000, @len) == [1]
  end

  test "boundaries_crossed: same epoch → none" do
    assert Epoch.boundaries_crossed(100, 200, @len) == []
    assert Epoch.boundaries_crossed(86_400, 86_500, @len) == []
  end

  test "boundaries_crossed: crossing one boundary → that epoch" do
    assert Epoch.boundaries_crossed(86_399, 86_400, @len) == [1]
    assert Epoch.boundaries_crossed(80_000, 90_000, @len) == [1]
  end

  test "boundaries_crossed: a gap spanning multiple boundaries lists each entered epoch" do
    # slot 10 (epoch 0) → slot 200_000 (epoch 2): entered epochs 1 and 2
    assert Epoch.boundaries_crossed(10, 200_000, @len) == [1, 2]
  end

  test "of/1 uses the resolved run params (Preview epoch length)" do
    # of/1 delegates to of/2 with params().epoch_length (86400) — the arity used in ingest.
    assert Epoch.of(0) == 0
    assert Epoch.of(86_400) == 1
    assert Epoch.of(200_000) == 2
  end

  test "params/0 returns Preview defaults (overridable via app env)" do
    p = Epoch.params()
    assert p.epoch_length == 86_400
    assert p.active_slots_coeff == {1, 20}
    assert p.max_lovelace_supply == 45_000_000_000_000_000
  end
end
