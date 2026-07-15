defmodule Cardamom.Ledger.VerdictTest do
  @moduledoc """
  The block VALIDATION VERDICT — pure aggregation of per-rule check results into an
  accept/reject decision. The validator architecture arriving via the observer (mirrors the
  header gate): rules return results, the verdict decides, POLICY acts on the decision.

  Decision semantics under test:
    * no results → :accept (an empty block violates nothing),
    * any {:violation, _} → :reject,
    * {:skip, _} NEVER rejects — a skip is an honestly-undecidable check, not a violation.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Verdict

  defp hash, do: <<0xAB::8, 0::248>>

  test "a fresh verdict (no results) accepts" do
    v = Verdict.new(hash(), 42)
    assert Verdict.decision(v) == :accept
    assert Verdict.violations(v) == []
  end

  test "passes and skips accept; skips are not violations" do
    v =
      Verdict.new(hash(), 42)
      |> Verdict.add(:value_conservation, :pass, txid: <<1::256>>)
      |> Verdict.add(:value_conservation, {:skip, :multiasset_not_balanced}, txid: <<2::256>>)

    assert Verdict.decision(v) == :accept
    assert Verdict.violations(v) == []
  end

  test "MC/DC: one violation among passes → reject; the violation is reported" do
    v =
      Verdict.new(hash(), 42)
      |> Verdict.add(:withdrawal_full_balance, :pass)
      |> Verdict.add(:value_conservation, {:violation, %{diff: 1_000}}, txid: <<1::256>>)

    assert Verdict.decision(v) == :reject
    assert [%{rule: :value_conservation, detail: %{diff: 1_000}}] = Verdict.violations(v)
  end

  test "results carry the Agda spec citation for their rule (test → spec traceability)" do
    v =
      Verdict.new(hash(), 42)
      |> Verdict.add(:value_conservation, :pass)
      |> Verdict.add(:withdrawal_full_balance, :pass)
      |> Verdict.add(:withdrawal_vote_delegated, :pass)

    specs = Enum.map(v.results, & &1.spec)
    assert Enum.any?(specs, &(&1 =~ "Utxo.lagda.md"))
    assert Enum.count(specs, &(&1 =~ "Certs.lagda.md")) == 2
  end

  test "add_all folds {rule, outcome, opts} tuples in order" do
    v =
      Verdict.add_all(Verdict.new(hash(), 1), [
        {:withdrawal_full_balance, :pass, [txid: <<1::256>>]},
        {:withdrawal_vote_delegated, {:violation, %{credential: "x"}}, [txid: <<1::256>>]}
      ])

    assert Verdict.decision(v) == :reject
    assert [%{rule: :withdrawal_vote_delegated}] = Verdict.violations(v)
  end

  test "summary: compact, hex-keyed, counts by outcome — the exit-reason / telemetry shape" do
    v =
      Verdict.new(hash(), 42)
      |> Verdict.add(:withdrawal_full_balance, :pass, txid: <<1::256>>)
      |> Verdict.add(:value_conservation, {:skip, :has_gov_proposals}, txid: <<1::256>>)
      |> Verdict.add(:value_conservation, {:violation, %{diff: -5}}, txid: <<2::256>>)

    s = Verdict.summary(v)
    assert s.decision == :reject
    assert s.slot == 42
    assert s.hash == Base.encode16(hash(), case: :lower)
    assert s.passes == 1
    assert s.skips == 1
    assert [%{rule: :value_conservation, txid: txid_hex, detail: %{diff: -5}}] = s.violations
    assert txid_hex == Base.encode16(<<2::256>>, case: :lower)
  end

  test "emit: telemetry [:cardamom, :ledger, :verdict] fires with counts + decision" do
    id = make_ref()
    me = self()

    :telemetry.attach(
      id,
      [:cardamom, :ledger, :verdict],
      fn _e, meas, meta, _c -> send(me, {:verdict, id, meas, meta}) end,
      nil
    )

    try do
      Verdict.new(hash(), 7)
      |> Verdict.add(:value_conservation, :pass)
      |> Verdict.add(:withdrawal_full_balance, {:violation, %{withdrawn: 1, our_balance: 2}})
      |> Verdict.emit()
    after
      :telemetry.detach(id)
    end

    assert_receive {:verdict, ^id, %{passes: 1, skips: 0, violations: 1}, %{decision: :reject}}
  end
end
