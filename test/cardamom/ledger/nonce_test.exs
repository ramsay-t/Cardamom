defmodule Cardamom.Ledger.NonceTest do
  @moduledoc """
  Epoch-nonce (η) evolution — the randomness beacon that seeds VRF leader election.
  Spec: consensus UPDN rule (Spec/UpdateNonce.lagda) + ledger BaseTypes Nonce ⭒ and
  mkNonceFromOutputVRF + StabilityWindow. All operations pinned from source (2026-08-04):

    * ⭒ (combine):  Nonce a ⭒ Nonce b = blake2b256(a ‖ b);  neutral is identity.
    * from VRF out: blake2b256(64-byte VRF output).
    * UPDN per block: η_evolving ← η_evolving ⭒ η_block; the CANDIDATE tracks it UNTIL
      slot + randomnessStabilisationWindow ≥ first slot of next epoch, then FREEZES.
    * epoch tick: η_epoch ← candidate ⭒ η_lastEpochLastBlock  (the lagged prev-hash nonce).
    * randomnessStabilisationWindow = ⌈4k/f⌉ (Preview k=432 f=1/20 ⇒ 34560).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Nonce

  # tiny params so a boundary is reachable in a handful of slots:
  # epoch_length 100, k=1, f=1/20 ⇒ window = ceil(4*1*20) = 80. candidate freezes once
  # slot + 80 ≥ next-epoch-first-slot.
  @params %{epoch_length: 100, security_param: 1, active_slots_coeff: {1, 20}}

  defp out(n), do: <<n::512>>

  test "⭒ combine: neutral is identity, and combining is blake2b256(a ‖ b)" do
    a = Nonce.from_vrf_output(out(1))
    assert Nonce.combine(:neutral, a) == a
    assert Nonce.combine(a, :neutral) == a

    b = Nonce.from_vrf_output(out(2))
    assert Nonce.combine(a, b) == Cardamom.Crypto.blake2b_256(a <> b)
    assert Nonce.combine(a, b) != Nonce.combine(b, a), "order matters"
  end

  test "from_vrf_output hashes the raw 64-byte VRF output to 32 bytes" do
    n = Nonce.from_vrf_output(out(7))
    assert byte_size(n) == 32
    assert n == Cardamom.Crypto.blake2b_256(out(7))
  end

  test "randomnessStabilisationWindow = ceil(4k/f)" do
    assert Nonce.stabilisation_window(%{security_param: 1, active_slots_coeff: {1, 20}}) == 80
    assert Nonce.stabilisation_window(%{security_param: 432, active_slots_coeff: {1, 20}}) == 34_560
  end

  describe "UPDN per-block update (evolving + candidate)" do
    test "before the window: BOTH evolving and candidate absorb the block nonce" do
      st = Nonce.initial(:neutral)
      # slot 10, epoch 0 (len 100); 10 + 80 = 90 < 100 ⇒ before window
      st = Nonce.update(st, 10, out(1), @params)
      expected = Nonce.combine(:neutral, Nonce.from_vrf_output(out(1)))
      assert st.evolving == expected
      assert st.candidate == expected
    end

    test "at/after the window: only EVOLVING absorbs; candidate FREEZES" do
      st = Nonce.initial(:neutral)
      st = Nonce.update(st, 10, out(1), @params)
      frozen = st.candidate
      # slot 25: 25 + 80 = 105 ≥ 100 ⇒ in the window; candidate must not move
      st = Nonce.update(st, 25, out(2), @params)
      assert st.candidate == frozen, "candidate frozen inside the stabilisation window"
      assert st.evolving == Nonce.combine(frozen, Nonce.from_vrf_output(out(2)))
    end
  end

  describe "epoch tick" do
    test "η_epoch = candidate ⭒ lastEpochLastBlockNonce; registers roll forward" do
      st = Nonce.initial(:neutral)
      st = Nonce.update(st, 10, out(1), @params)
      candidate = st.candidate
      lab = Nonce.from_vrf_output(out(9))

      st2 = Nonce.tick_epoch(st, lab)
      assert st2.epoch == Nonce.combine(candidate, lab)
      # evolving/candidate reset to the fresh epoch nonce for the new epoch
      assert st2.evolving == st2.epoch
      assert st2.candidate == st2.epoch
    end
  end

  test "a full epoch fold: process ordered (slot, vrf_out) then tick, deterministically" do
    blocks = for s <- [5, 30, 60, 95], do: {s, out(s)}
    st = Enum.reduce(blocks, Nonce.initial(:neutral), fn {s, o}, acc -> Nonce.update(acc, s, o, @params) end)
    # candidate froze at the first slot with s+80≥100, i.e. slot 30; blocks 60,95 only move evolving
    st2 = Nonce.update(Nonce.initial(:neutral), 5, out(5), @params)
    st2 = Nonce.update(st2, 30, out(30), @params)
    assert st.candidate == st2.candidate
    assert st.evolving != st.candidate
  end
end
