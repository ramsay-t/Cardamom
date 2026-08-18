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
  #
  # NOTE these tests exercise the WITHDRAWAL and CONSERVATION rules in isolation; BlockBuilder
  # emits UNSIGNED synthetic txs, so witness COVERAGE will flag the (unwitnessed) reward-account
  # key-hash. That is correct behaviour (a real withdrawal carries the stake key's signature),
  # tested in witness_check_test; here we scope assertions to the rule under test via
  # `violation_for/2` rather than demand an exact single-violation list.
  defp withdrawal_block(slot, withdrawn, fee) do
    BlockBuilder.build(slot: slot, bodies: [%{2 => fee, 5 => %{key_addr(1) => withdrawn}}])
  end

  defp violation_for(rule, summary), do: Enum.filter(summary.violations, &(&1.rule == rule))

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

  test "conformant SIGNED block ACCEPTS: all checks pass, effects committed, verdict emitted" do
    # A REAL keypair: the reward account's key-hash is blake2b_224(vk), and the tx is signed by
    # sk — so withdrawal, conservation AND witness coverage all pass (a genuinely valid block).
    sk = :crypto.strong_rand_bytes(32)
    {vk, _} = :crypto.generate_key(:eddsa, :ed25519, sk)
    kh = Cardamom.Crypto.blake2b_224(vk)
    cred = {:key, kh}
    reward_addr = %CBOR.Tag{tag: :bytes, value: <<0xE0, kh::binary>>}

    # withdrawal == fee (conservation), and fee ≥ minFee (economic rule): use a realistic 200k.
    seed_reward(cred, 200_000)

    block =
      BlockBuilder.build(
        slot: 10,
        bodies: [%{2 => 200_000, 5 => %{reward_addr => 200_000}}],
        sign_with: [sk]
      )

    verdicts = capture_verdicts(fn -> assert :ok = ChainStore.process_block(block.raw, 10) end)

    # committed: the account zeroed (the PRE-CERT effect), fees accrued
    assert ChainStore.ledger_read(:reward, cred) == 0
    assert ChainStore.ledger_read(:fees, :pot) == 200_000

    # every check passed, block accepted
    assert [{%{violations: 0}, %{decision: :accept}}] = verdicts
  end

  test "withdrawal-rule violation REJECTS AT THE GATE: no delta applied, no self-heal" do
    seed_reward(k(1), 4_999)
    block = withdrawal_block(10, 5_000, 5_000)

    verdicts =
      capture_verdicts(fn ->
        assert {:error, {:validation_rejected, summary}} = ChainStore.process_block(block.raw, 10)
        # scoped to the rule under test (the unsigned synthetic tx also trips witness coverage)
        assert [%{rule: :withdrawal_full_balance, detail: %{withdrawn: 5_000, our_balance: 4_999}}] =
                 violation_for(:withdrawal_full_balance, summary)
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
    assert [%{rule: :withdrawal_vote_delegated}] = violation_for(:withdrawal_vote_delegated, summary)
  end

  test "conservation violation REJECTS AT COMPLETION: block parks unprocessed" do
    # Must PASS the gate (signed, sig+coverage+min_fee ok) so extraction runs and conservation is
    # checked at completion — then fail conservation: consumed 200_000 (withdrawal), produced
    # 199_000 (fee, still ≥ minFee), 1_000 unaccounted (Utxo.lagda.md:437-449).
    sk = :crypto.strong_rand_bytes(32)
    {vk, _} = :crypto.generate_key(:eddsa, :ed25519, sk)
    kh = Cardamom.Crypto.blake2b_224(vk)
    cred = {:key, kh}
    reward_addr = %CBOR.Tag{tag: :bytes, value: <<0xE0, kh::binary>>}

    seed_reward(cred, 200_000)

    block =
      BlockBuilder.build(slot: 10, bodies: [%{2 => 199_000, 5 => %{reward_addr => 200_000}}], sign_with: [sk])

    assert {:error, {:validation_rejected, summary}} = ChainStore.process_block(block.raw, 10)

    assert [%{rule: :value_conservation, detail: %{diff: 1_000}}] =
             violation_for(:value_conservation, summary)

    # this check runs post-resolution, so the delta HAS applied (account zeroed) — but the block
    # is NOT marked processed: the reconciler will re-hit it and re-alarm (self-announcing stop).
    assert ChainStore.ledger_read(:reward, cred) == 0
  end

  test "empty block (no txs, nothing to violate) accepts with an empty verdict" do
    block = BlockBuilder.build(slot: 10, tx_count: 0)

    verdicts = capture_verdicts(fn -> assert :ok = ChainStore.process_block(block.raw, 10) end)

    assert [{%{passes: 0, skips: 0, violations: 0}, %{decision: :accept}}] = verdicts
  end

  test "a proposal-bearing block records the GovActionState in :gov ledger state" do
    # a signed tx whose sole content is one info-action proposal (deposit balanced by an input)
    sk = :crypto.strong_rand_bytes(32)
    {vk, _} = :crypto.generate_key(:eddsa, :ed25519, sk)
    kh = Cardamom.Crypto.blake2b_224(vk)
    reward_addr = %CBOR.Tag{tag: :bytes, value: <<0xE0, kh::binary>>}
    # input at a key address owned by sk (so witness coverage + sig pass), 40M covers the deposit
    in_addr = <<0x00, kh::binary, 0::224>>
    src = <<3::256>>
    # input 40.2M = deposit 40M (produced) + fee 200k (produced, ≥ minFee) → conservation holds
    ChainStore.insert_txo(src, 0, %{address: in_addr, value: 40_200_000, datum_hash: nil, datum: nil}, 1)

    proposal = [40_000_000, reward_addr, [6], nil]
    body = %{0 => [[%CBOR.Tag{tag: :bytes, value: src}, 0]], 2 => 200_000, 20 => [proposal]}
    block = BlockBuilder.build(slot: 10, bodies: [body], sign_with: [sk])

    assert :ok = ChainStore.process_block(block.raw, 10)

    # the gov action is keyed by {txid, 0}; the tx id is blake2b-256 of the body bytes
    {:ok, [tx]} = Cardamom.Ledger.Block.txs_in(block.raw)
    state = ChainStore.ledger_read(:gov, {tx.txid, 0})
    assert %{action: :info_action, expires_in: expires, votes: %{}} = state
    # epoch of slot 10 + govActionLifetime (30 default) — just assert it's set & in the future
    assert expires > Cardamom.Ledger.Epoch.of(10)
  end
end
