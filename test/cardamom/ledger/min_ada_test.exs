defmodule Cardamom.Ledger.MinAdaTest do
  @moduledoc """
  min-UTxO is a SWAPPABLE POLICY, not baked-in logic (Ramsay, 2026-08-14: the min-ADA system is
  about to change in a possibly-weird way — e.g. a small value plus surplus directed to an
  account rather than an integer per-UTxO floor — so the WHOLE computation, formula AND decision
  shape, must sit behind a seam that a future policy replaces without touching EconomicRules).

  `Cardamom.Ledger.MinAda` is a behaviour (names matching the Haskell source): `get_min_coin_tx_out(output, params) :: non_neg_integer | :unknown`
  gives the minimum coin an output must hold (`:unknown` when un-computable → the caller SKIPS).
  Current impl `MinAda.Babbage` = `coinsPerUTxOByte · (|output| + overhead)`, both values from
  params (nothing hardcoded in the formula body). The active policy is resolved via app-env, so a
  new era's rule is a config swap.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.MinAda

  # NB the result is a MINIMUM RETAINED VALUE (the ADA stays locked in the UTxO — not consumed,
  # not a fee); the constant_overhead is a cost-model term the ledger uses to size that minimum.
  test "Babbage policy: minimum = coinsPerUTxOByte · (constant_overhead + size), from params" do
    out = %{value: 0, raw: <<0, 1, 2, 3>>}
    params = %{coins_per_utxo_byte: 4310, constant_overhead: 160}
    assert MinAda.Babbage.get_min_coin_tx_out(out, params) == 4310 * (160 + 4)
  end

  test "Babbage policy: the cost-model constant is PARAMETERISED (not a magic number)" do
    out = %{value: 0, raw: <<0>>}
    assert MinAda.Babbage.get_min_coin_tx_out(out, %{coins_per_utxo_byte: 1, constant_overhead: 999}) == 1 * (999 + 1)
    # a different constant flows straight through — nothing is baked in
    assert MinAda.Babbage.get_min_coin_tx_out(out, %{coins_per_utxo_byte: 1, constant_overhead: 0}) == 1
  end

  test "Babbage policy: :unknown when the coin-per-byte param is absent" do
    assert MinAda.Babbage.get_min_coin_tx_out(%{value: 0, raw: <<0>>}, %{}) == :unknown
    assert MinAda.Babbage.get_min_coin_tx_out(%{value: 0, raw: <<0>>}, %{coins_per_utxo_byte: nil}) == :unknown
  end

  test "the active policy is resolved via app-env (swap = config, not code)" do
    assert MinAda.policy() == MinAda.Babbage

    Application.put_env(:cardamom, :min_ada_policy, MinAda.Babbage)
    on_exit(fn -> Application.delete_env(:cardamom, :min_ada_policy) end)
    assert MinAda.policy() == MinAda.Babbage
  end

  test "MinAda.get_min_coin_tx_out delegates to the active policy" do
    params = %{coins_per_utxo_byte: 100, constant_overhead: 10}
    assert MinAda.get_min_coin_tx_out(%{value: 0, raw: <<0, 0>>}, params) == 100 * (2 + 10)
  end
end
