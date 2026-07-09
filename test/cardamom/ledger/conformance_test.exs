defmodule Cardamom.Ledger.ConformanceTest do
  @moduledoc """
  Value-conservation oracle (Conway Utxo.lagda.md:437-449,547 — consumed ≡ produced). The check
  resolves input values from OUR UTxO set, so it self-checks our tracking too. Two layers:

    * UNIT — synthetic decoded-tx maps with controlled numbers, exercising :ok / :diverge / every
      :skip reason precisely (this is where the arithmetic is proven);
    * REAL — a real Preview block whose tx has CERTS (deposits we don't decode yet) must SKIP,
      not false-alarm, even though its raw inputs≠outputs+fee (the gap IS the deposit).
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.Ledger.Conformance
  alias Cardamom.Store.Txo
  alias Cardamom.Store.Repo

  # Seed a UTxO so an input can resolve to a value.
  defp seed_txo(txid, ix, value) do
    {:ok, _} = Repo.insert(%Txo{txid: txid, ix: ix, value: value})
  end

  defp tx(fields) do
    Map.merge(%{valid: true, inputs: [], outputs: [], fee: 0, withdrawals: [], certs: nil, donation: nil, txid: <<0::256>>}, fields)
  end

  defp out(v), do: %{value: v, multiasset: nil}

  test ":ok when Σ inputs == Σ outputs + fee (simple balanced tx)" do
    a = <<1::256>>
    seed_txo(a, 0, 1_000_000)
    t = tx(%{inputs: [{a, 0}], outputs: [out(800_000)], fee: 200_000})
    assert Conformance.check_value_conservation(t) == :ok
  end

  test ":ok with a withdrawal as a source of value" do
    a = <<2::256>>
    seed_txo(a, 0, 1_000_000)
    # input 1_000_000 + withdrawal 500_000 == outputs 1_300_000 + fee 200_000
    t = tx(%{inputs: [{a, 0}], outputs: [out(1_300_000)], fee: 200_000, withdrawals: [{<<9>>, 500_000}]})
    assert Conformance.check_value_conservation(t) == :ok
  end

  test ":diverge when the equation does NOT balance (our state drifted)" do
    a = <<3::256>>
    seed_txo(a, 0, 1_000_000)
    # outputs+fee = 900_000, but input says 1_000_000 → 100_000 unaccounted.
    t = tx(%{inputs: [{a, 0}], outputs: [out(700_000)], fee: 200_000})
    assert {:diverge, %{diff: 100_000, consumed: 1_000_000, produced: 900_000}} =
             Conformance.check_value_conservation(t)
  end

  test ":skip unresolved_input when an input isn't in our UTxO set" do
    t = tx(%{inputs: [{<<0xAB::256>>, 0}], outputs: [out(1)], fee: 0})
    assert {:skip, {:unresolved_input, _}} = Conformance.check_value_conservation(t)
  end

  test ":skip has_certs (deposits/refunds not decoded yet)" do
    t = tx(%{inputs: [], outputs: [], certs: [[0, "x"]]})
    assert {:skip, :has_certs} = Conformance.check_value_conservation(t)
  end

  test ":skip multiasset (ADA-only equation can't balance assets)" do
    t = tx(%{outputs: [%{value: 1, multiasset: %{"policy" => %{"tok" => 1}}}]})
    assert {:skip, :multiasset_not_balanced} = Conformance.check_value_conservation(t)
  end

  test ":skip an invalid (phase-2) tx — it conserves over collateral, a different equation" do
    assert {:skip, :invalid_tx_collateral_path} = Conformance.check_value_conservation(tx(%{valid: false}))
  end

  # REAL DATA: block 16's tx has stake+pool registration CERTS, so input ≠ outputs+fee (the gap is
  # the registration DEPOSITS, which we don't decode yet). The oracle must SKIP it, NOT diverge —
  # proving we don't false-alarm on a real cert-bearing tx. (Seed block 3's output first so the
  # input WOULD resolve; the skip is due to certs, not an unresolved input.)
  defp fixture(n) do
    Path.join([__DIR__, "..", "..", "fixtures", "blocks", "block-#{n}.hex"])
    |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
  end

  test "REAL: a cert-bearing block-16 tx SKIPS (has_certs), never false-diverges" do
    {:ok, [t16]} = Cardamom.Ledger.Conway.Tx.txs_in(fixture(16))
    assert {:skip, :has_certs} = Conformance.check_value_conservation(t16)
  end
end
