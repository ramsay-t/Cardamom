defmodule Cardamom.Ledger.EconomicRulesTest do
  @moduledoc """
  Phase-1 ECONOMIC / structural rules (Conway UTXO), each returning a verdict tuple:

    * :validity_interval — the block slot lies in [invalid_before, invalid_hereafter)
      (lower inclusive, upper EXCLUSIVE); absent bound = unbounded. Needs only the slot.
    * :min_fee — fee ≥ minFee. minFee = a·size + b (+ Conway ref-script tier). We only have the
      tx BODY size here, and minFee is over the WHOLE tx, so we assert a NECESSARY LOWER BOUND
      (fee ≥ a·body_size + b): a real underpayment still trips it, but we never over-reject.
      Skips when the fee params are absent (pp-tracking gap — honest, no guessed value).
    * :min_ada — each output's coin ≥ minUTxO(output). Skips when coinsPerUTxOByte is unknown
      (Preview conway-genesis omits it: it's an enacted param, not genesis — pp-tracking TODO).
    * :max_tx_size — body_size ≤ maxTxSize.

  Rules that can't yet be computed SKIP rather than guess — same discipline as the conservation
  oracle's unresolved input.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.EconomicRules, as: R

  defp r(rule, results), do: Enum.find(results, &(elem(&1, 0) == rule))

  # ---- validity interval ----

  test "validity interval: slot inside [before, hereafter) passes" do
    tx = %{txid: <<1::256>>, invalid_before: 100, invalid_hereafter: 200}
    assert {:validity_interval, :pass, _} = r(:validity_interval, R.check(tx, ctx(slot: 150)))
  end

  test "validity interval: slot == hereafter is a VIOLATION (upper is exclusive)" do
    tx = %{txid: <<1::256>>, invalid_before: nil, invalid_hereafter: 200}
    assert {:validity_interval, {:violation, _}, _} = r(:validity_interval, R.check(tx, ctx(slot: 200)))
  end

  test "validity interval: slot < before is a VIOLATION (lower is inclusive → before-1 fails)" do
    tx = %{txid: <<1::256>>, invalid_before: 100, invalid_hereafter: nil}
    assert {:validity_interval, {:violation, _}, _} = r(:validity_interval, R.check(tx, ctx(slot: 99)))
    assert {:validity_interval, :pass, _} = r(:validity_interval, R.check(tx, ctx(slot: 100)))
  end

  test "validity interval: no bounds at all → pass (unbounded)" do
    tx = %{txid: <<1::256>>, invalid_before: nil, invalid_hereafter: nil}
    assert {:validity_interval, :pass, _} = r(:validity_interval, R.check(tx, ctx(slot: 5)))
  end

  test "validity interval: SKIPS when the block slot is unknown" do
    tx = %{txid: <<1::256>>, invalid_before: 1, invalid_hereafter: 9}
    assert {:validity_interval, {:skip, _}, _} = r(:validity_interval, R.check(tx, ctx([])))
  end

  # ---- min fee (necessary lower bound over the body size) ----

  test "min_fee: a fee below a·body_size + b is a violation" do
    tx = %{txid: <<1::256>>, fee: 100, body_size: 200}
    # a=44, b=155381 ⇒ lower bound 44*200+155381 = 164181; fee 100 < that
    assert {:min_fee, {:violation, d}, _} = r(:min_fee, R.check(tx, ctx(slot: 1, min_fee_a: 44, min_fee_b: 155_381)))
    assert d.min_bound == 164_181
  end

  test "min_fee: a comfortably-sufficient fee passes" do
    tx = %{txid: <<1::256>>, fee: 200_000, body_size: 200}
    assert {:min_fee, :pass, _} = r(:min_fee, R.check(tx, ctx(slot: 1, min_fee_a: 44, min_fee_b: 155_381)))
  end

  test "min_fee: SKIPS when fee params are absent (pp-tracking gap)" do
    tx = %{txid: <<1::256>>, fee: 100, body_size: 200}
    assert {:min_fee, {:skip, _}, _} = r(:min_fee, R.check(tx, ctx(slot: 1)))
  end

  # ---- max tx size ----

  test "max_tx_size: over the cap is a violation; under passes" do
    ctx = ctx(slot: 1, max_tx_size: 16_384)
    assert {:max_tx_size, {:violation, _}, _} = r(:max_tx_size, R.check(%{txid: <<1::256>>, body_size: 20_000}, ctx))
    assert {:max_tx_size, :pass, _} = r(:max_tx_size, R.check(%{txid: <<1::256>>, body_size: 500}, ctx))
  end

  # ---- min ada ----

  test "min_ada: SKIPS when coinsPerUTxOByte is unknown (Preview genesis omits it)" do
    tx = %{txid: <<1::256>>, outputs: [%{value: 1, raw: <<0, 1, 2>>}]}
    assert {:min_ada, {:skip, _}, _} = r(:min_ada, R.check(tx, ctx(slot: 1)))
  end

  test "min_ada: with a param, an output below its floor is a violation" do
    # minUTxO = coins_per_utxo_byte * (output_bytes + 160 overhead). Tiny coin, real param.
    tx = %{txid: <<1::256>>, outputs: [%{value: 1, raw: <<0, 1, 2, 3>>}]}
    ctx = ctx(slot: 1, coins_per_utxo_byte: 4310)
    assert {:min_ada, {:violation, _}, _} = r(:min_ada, R.check(tx, ctx))
  end

  test "all results carry the txid" do
    tx = %{txid: <<9::256>>, invalid_before: nil, invalid_hereafter: nil, body_size: 1, fee: 0, outputs: []}
    results = R.check(tx, ctx(slot: 1))
    assert Enum.all?(results, fn {_r, _o, opts} -> Keyword.get(opts, :txid) == <<9::256>> end)
  end

  defp ctx(opts), do: Map.new(opts)
end
