defmodule Cardamom.Ledger.ConformanceTest do
  @moduledoc """
  Value-conservation oracle (Conway Utxo.lagda.md:437-449,547 — consumed ≡ produced). The check
  resolves input values from OUR UTxO set, so it self-checks our tracking too. Two layers:

    * UNIT — synthetic decoded-tx maps with controlled numbers, exercising :ok / :diverge / every
      :skip reason precisely (this is where the arithmetic is proven). Cert deposit/refund terms
      are costed from decoded certs (explicit Conway coins; legacy tag-0/1 at keyDeposit);
    * REAL — a real Preview block whose tx has a POOL registration cert must SKIP for exactly
      that reason (its deposit is charged only-if-new — state-dependent), not false-alarm.
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

  # ---- cert deposit terms (Utxo.lagda.md consumed/produced deposit halves) ----

  test ":ok with an explicit-deposit registration cert (tag 7): the deposit is PRODUCED" do
    a = <<4::256>>
    seed_txo(a, 0, 3_000_000)
    # input 3M == output 800k + fee 200k + deposit 2M
    cert = [7, [0, <<1::224>>], 2_000_000]
    t = tx(%{inputs: [{a, 0}], outputs: [out(800_000)], fee: 200_000, certs: [cert]})
    assert Conformance.check_value_conservation(t) == :ok
  end

  test ":ok with an explicit-refund deregistration cert (tag 8): the refund is CONSUMED" do
    a = <<5::256>>
    seed_txo(a, 0, 1_000_000)
    # input 1M + refund 2M == output 2.8M + fee 200k
    cert = [8, [0, <<1::224>>], 2_000_000]
    t = tx(%{inputs: [{a, 0}], outputs: [out(2_800_000)], fee: 200_000, certs: [cert]})
    assert Conformance.check_value_conservation(t) == :ok
  end

  test ":ok with a legacy no-coin registration (tag 0) costed at the protocol keyDeposit" do
    a = <<6::256>>
    seed_txo(a, 0, 3_000_000)
    # keyDeposit is 2_000_000 (ChainStore.protocol_deposits)
    t = tx(%{inputs: [{a, 0}], outputs: [out(800_000)], fee: 200_000, certs: [[0, [0, <<1::224>>]]]})
    assert Conformance.check_value_conservation(t) == :ok
  end

  test ":diverge when a deposit-bearing tx does NOT balance (deposit terms in the detail)" do
    a = <<7::256>>
    seed_txo(a, 0, 3_000_000)
    # input 3M vs 800k + 200k + 2M deposit + spurious 100k output → produced exceeds consumed
    cert = [7, [0, <<1::224>>], 2_000_000]
    t = tx(%{inputs: [{a, 0}], outputs: [out(900_000)], fee: 200_000, certs: [cert]})
    assert {:diverge, %{diff: -100_000, deposits_made: 2_000_000}} =
             Conformance.check_value_conservation(t)
  end

  test ":ok with a value-free delegation cert (no deposit term)" do
    a = <<8::256>>
    seed_txo(a, 0, 1_000_000)
    cert = [2, [0, <<1::224>>], <<2::224>>]
    t = tx(%{inputs: [{a, 0}], outputs: [out(800_000)], fee: 200_000, certs: [cert]})
    assert Conformance.check_value_conservation(t) == :ok
  end

  test ":skip a pool registration cert (deposit charged only-if-new — state-dependent)" do
    pool_cert = [3, <<1::224>>, <<2::256>>, 100, 340_000_000, [1, 10], <<0xE0, 3::224>>, [], [], nil]
    t = tx(%{inputs: [], outputs: [], certs: [pool_cert]})
    assert {:skip, :pool_reg_deposit_state_dependent} = Conformance.check_value_conservation(t)
  end

  test ":skip an unknown cert type (future tag)" do
    t = tx(%{inputs: [], outputs: [], certs: [[99, "future"]]})
    assert {:skip, {:unknown_cert, 99}} = Conformance.check_value_conservation(t)
  end

  test ":skip a tx carrying governance proposals (govActionDeposit not decoded yet)" do
    t = tx(%{inputs: [], outputs: [], proposals: [[:some, :proposal]]})
    assert {:skip, :has_gov_proposals} = Conformance.check_value_conservation(t)
  end

  test ":skip multiasset (ADA-only equation can't balance assets)" do
    t = tx(%{outputs: [%{value: 1, multiasset: %{"policy" => %{"tok" => 1}}}]})
    assert {:skip, :multiasset_not_balanced} = Conformance.check_value_conservation(t)
  end

  test ":skip an invalid (phase-2) tx — it conserves over collateral, a different equation" do
    assert {:skip, :invalid_tx_collateral_path} = Conformance.check_value_conservation(tx(%{valid: false}))
  end

  # REAL DATA: block 16's tx registers a stake credential AND a POOL. Stake-reg deposits are now
  # costed, but the pool deposit is charged only-if-new (state-dependent), so the oracle must SKIP
  # for exactly that reason — NOT diverge, and NOT silently pass.
  defp fixture(n) do
    Path.join([__DIR__, "..", "..", "fixtures", "blocks", "block-#{n}.hex"])
    |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
  end

  test "REAL: block-16's pool-registering tx SKIPS for the pool-deposit reason, never false-diverges" do
    {:ok, [t16]} = Cardamom.Ledger.Conway.Tx.txs_in(fixture(16))
    assert {:skip, :pool_reg_deposit_state_dependent} = Conformance.check_value_conservation(t16)
  end
end
