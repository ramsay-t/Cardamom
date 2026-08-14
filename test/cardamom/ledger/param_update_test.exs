defmodule Cardamom.Ledger.ParamUpdateTest do
  @moduledoc """
  ENACTED protocol-parameter tracking — the mechanism (not yet the ratification POLICY). A
  parameter-change gov action, once ENACTED, updates the live protocol-parameter set; we model
  that as INVERTIBLE per-key delta ops in a `:pparams` ledger domain (so it journals + rolls back
  like every other ledger effect). This is what turns the min_fee / min_ada rules from skip to
  assert: they read live pparams instead of a static genesis map.

  SCOPE (deliberately bounded): this builds the ENACTMENT ops (apply a decoded
  protocol_param_update to current pparams) + the read/seed path. The RATIFICATION decision —
  which proposals reach enactment, vote tallies, thresholds, the ratification delay — is a
  further layer (the gov half of the epoch); until it lands, enactment is driven explicitly.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.ParamUpdate

  # read: (:pparams, key) -> current value | nil
  defp read(m), do: fn :pparams, k -> Map.get(m, k) end

  test "enact ops: one {:set, :pparams, key, old, new} per changed param" do
    current = read(%{min_fee_a: 44, min_fee_b: 155_381})
    update = %{min_fee_a: 50}

    ops = ParamUpdate.enact_ops(update, current)
    assert ops == [{:set, :pparams, :min_fee_a, 44, 50}]
  end

  test "enact ops: a brand-new param (nil old) is captured for invertibility" do
    current = read(%{})
    ops = ParamUpdate.enact_ops(%{coins_per_utxo_byte: 4310}, current)
    assert ops == [{:set, :pparams, :coins_per_utxo_byte, nil, 4310}]
  end

  test "enact ops: unchanged params produce NO op (a no-op set is not journalled)" do
    current = read(%{min_fee_a: 44})
    assert ParamUpdate.enact_ops(%{min_fee_a: 44}, current) == []
  end

  test "enact ops: multiple keys, deterministic order" do
    current = read(%{min_fee_a: 44, min_fee_b: 155_381, coins_per_utxo_byte: nil})
    update = %{min_fee_a: 50, min_fee_b: 160_000, coins_per_utxo_byte: 4310}

    ops = ParamUpdate.enact_ops(update, current)
    assert Enum.sort(ops) == Enum.sort([
             {:set, :pparams, :min_fee_a, 44, 50},
             {:set, :pparams, :min_fee_b, 155_381, 160_000},
             {:set, :pparams, :coins_per_utxo_byte, nil, 4310}
           ])
  end

  test "current_params: overlays enacted :pparams onto genesis defaults" do
    defaults = %{min_fee_a: 44, min_fee_b: 155_381, coins_per_utxo_byte: nil}
    # min_fee_a enacted to 50, coins_per_utxo_byte enacted to 4310; min_fee_b untouched
    read = read(%{min_fee_a: 50, coins_per_utxo_byte: 4310})

    params = ParamUpdate.current_params(defaults, read)
    assert params.min_fee_a == 50
    assert params.min_fee_b == 155_381
    assert params.coins_per_utxo_byte == 4310
  end

  test "current_params: no enacted overrides ⇒ genesis defaults verbatim" do
    defaults = %{min_fee_a: 44, min_fee_b: 155_381}
    assert ParamUpdate.current_params(defaults, read(%{})) == defaults
  end
end
