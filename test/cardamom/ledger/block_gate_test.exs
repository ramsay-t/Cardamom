defmodule Cardamom.Ledger.BlockGateTest do
  @moduledoc """
  The BLOCK VALIDATION GATE end-to-end, through the REAL pipeline (process_block →
  BlockHandler → Verdict): structurally-real Conway blocks (BlockBuilder) carrying REAL
  decodable tx bodies.

  Policy under test (stop-and-fix, see Cardamom.Ledger.Verdict):
    * a rule-conformant block ACCEPTS — verdict emitted, effects committed, extraction :ok;
    * a withdrawal-rule violation (Certs.lagda.md:596-607) REJECTS AT THE GATE — the ledger
      delta is NOT applied (no self-heal) and the caller gets {:validation_rejected, summary};
    * a value-conservation violation (Utxo.lagda.md:437-449) REJECTS AT COMPLETION — it can
      only be checked once inputs resolve, after the delta applied, but the block still parks
      unprocessed and the rejection surfaces identically.

  On real chain data a reject is an ASSERTION FAILURE (expected never to fire) — these tests
  manufacture the failure to prove the gate stops us when our derivation is wrong.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Conway.BlockBuilder

  defp h(n), do: <<n::224>>
  defp k(n), do: {:key, h(n)}
  defp key_addr(n), do: %CBOR.Tag{tag: :bytes, value: <<0xE0, h(n)::binary>>}

  defp seed_reward(cred, balance, opts \\ []) do
    ops = [{:set, :reward, cred, nil, balance}]

    ops =
      if Keyword.get(opts, :vote_delegated, true),
        do: ops ++ [{:set, :vote_deleg, cred, nil, :drep_seed}],
        else: ops

    ChainStore.ledger_apply_block(<<1::256>>, 1, ops)
  end

  # A block whose single tx withdraws `withdrawn` and pays it all as `fee` (inputs/outputs
  # empty, so conservation is: withdrawn == fee).
  defp withdrawal_block(slot, withdrawn, fee) do
    BlockBuilder.build(slot: slot, bodies: [%{2 => fee, 5 => %{key_addr(1) => withdrawn}}])
  end

  defp capture_verdicts(fun) do
    id = make_ref()
    me = self()

    :telemetry.attach(
      id,
      [:cardamom, :ledger, :verdict],
      fn _e, meas, meta, _c -> send(me, {:verdict, id, meas, meta}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect(id, [])
  end

  defp collect(id, acc) do
    receive do
      {:verdict, ^id, meas, meta} -> collect(id, [{meas, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "conformant block ACCEPTS: all checks pass, effects committed, verdict emitted" do
    seed_reward(k(1), 5_000)
    block = withdrawal_block(10, 5_000, 5_000)

    verdicts = capture_verdicts(fn -> assert :ok = ChainStore.process_block(block.raw, 10) end)

    # committed: the account zeroed (the PRE-CERT effect), fees accrued
    assert ChainStore.ledger_read(:reward, k(1)) == 0
    assert ChainStore.ledger_read(:fees, :pot) == 5_000

    # verdict: 2 withdrawal checks + conservation, all passes
    assert [{%{passes: 3, skips: 0, violations: 0}, %{decision: :accept}}] = verdicts
  end

  test "withdrawal-rule violation REJECTS AT THE GATE: no delta applied, no self-heal" do
    seed_reward(k(1), 4_999)
    block = withdrawal_block(10, 5_000, 5_000)

    verdicts =
      capture_verdicts(fn ->
        assert {:error, {:validation_rejected, summary}} = ChainStore.process_block(block.raw, 10)
        assert [%{rule: :withdrawal_full_balance, detail: %{withdrawn: 5_000, our_balance: 4_999}}] =
                 summary.violations
      end)

    # the gate withheld the COMMIT: balance NOT zeroed (old stance would have self-healed to 0),
    # no fee accrual, no epoch bootstrap — the block's delta never applied
    assert ChainStore.ledger_read(:reward, k(1)) == 4_999
    assert ChainStore.ledger_read(:fees, :pot) == nil
    assert ChainStore.ledger_read(:epoch, :last_epoch) == nil

    assert [{_meas, %{decision: :reject}}] = verdicts
  end

  test "MC/DC: missing vote delegation alone REJECTS (balance exact, delegation absent)" do
    seed_reward(k(1), 5_000, vote_delegated: false)
    block = withdrawal_block(10, 5_000, 5_000)

    assert {:error, {:validation_rejected, summary}} = ChainStore.process_block(block.raw, 10)
    assert [%{rule: :withdrawal_vote_delegated}] = summary.violations
  end

  test "conservation violation REJECTS AT COMPLETION: block parks unprocessed" do
    seed_reward(k(1), 5_000)
    # withdrawal checks pass (5_000 == 5_000) but the tx keeps 1_000 unaccounted:
    # consumed = 5_000 (withdrawal), produced = 4_000 (fee) — Utxo.lagda.md:437-449 violated.
    block = withdrawal_block(10, 5_000, 4_000)

    assert {:error, {:validation_rejected, summary}} = ChainStore.process_block(block.raw, 10)

    assert [%{rule: :value_conservation, detail: %{diff: 1_000}}] = summary.violations

    # this check runs post-resolution, so the delta HAS applied (account zeroed) — but the block
    # is NOT marked processed: the reconciler will re-hit it and re-alarm (self-announcing stop).
    assert ChainStore.ledger_read(:reward, k(1)) == 0
  end

  test "empty block (no txs, nothing to violate) accepts with an empty verdict" do
    block = BlockBuilder.build(slot: 10, tx_count: 0)

    verdicts = capture_verdicts(fn -> assert :ok = ChainStore.process_block(block.raw, 10) end)

    assert [{%{passes: 0, skips: 0, violations: 0}, %{decision: :accept}}] = verdicts
  end
end
