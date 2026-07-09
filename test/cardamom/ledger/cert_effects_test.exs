defmodule Cardamom.Ledger.CertEffectsTest do
  @moduledoc """
  Cert STATE EFFECTS + the INVERTIBLE delta journal (the rollback mechanism). The headline
  property: apply a block's cert deltas, then roll back, and the ledger state is EXACTLY as before
  — including the hard case, a destructive OVERWRITE (re-delegation), which is only invertible
  because the :set op captured the displaced old value.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{ChainStore, Ledger.Cert, Ledger.CertEffects, Ledger.Delta}

  @pp %{key_deposit: 2_000_000, pool_deposit: 500_000_000, drep_deposit: 500_000}

  defp read, do: fn dom, key -> ChainStore.ledger_read(dom, key) end

  # Build ops for a decoded cert against current state, then journal+apply them as a "block".
  defp apply_cert(cert, slot) do
    ops = CertEffects.effects(cert, read(), @pp)
    ChainStore.ledger_apply_block(<<slot::256>>, slot, ops)
    ops
  end

  defp cred, do: {:key, <<7::224>>}

  test "stake registration creates a reward entry + a deposit; deregistration reverses both" do
    apply_cert(%{type: :stake_registration, credential: cred()}, 100)
    assert ChainStore.ledger_read(:reward, cred()) == 0
    assert ChainStore.ledger_read(:deposit, {:cred, cred()}) == @pp.key_deposit

    apply_cert(%{type: :stake_deregistration, credential: cred()}, 200)
    assert ChainStore.ledger_read(:reward, cred()) == nil
    # deposit refunded: 2_000_000 + (-2_000_000) = 0
    assert (ChainStore.ledger_read(:deposit, {:cred, cred()}) || 0) == 0
  end

  test "stake delegation OVERWRITES, and rollback restores the PREVIOUS pool (the hard case)" do
    # register + delegate to pool A at slot 100
    apply_cert(%{type: :stake_registration, credential: cred()}, 100)
    apply_cert(%{type: :stake_delegation, credential: cred(), pool: "poolA"}, 110)
    assert ChainStore.ledger_read(:stake_deleg, cred()) == "poolA"

    # RE-delegate to pool B at slot 120 (destructive overwrite)
    apply_cert(%{type: :stake_delegation, credential: cred(), pool: "poolB"}, 120)
    assert ChainStore.ledger_read(:stake_deleg, cred()) == "poolB"

    # ROLL BACK to slot 115 — undoes the poolB delegation; must restore poolA (NOT nil).
    ChainStore.ledger_rollback(115)
    assert ChainStore.ledger_read(:stake_deleg, cred()) == "poolA",
           "rollback of an overwrite restores the displaced old value"
  end

  test "full round-trip: apply a mixed block then roll back → state identical to before" do
    before = snapshot()

    # A block: register, delegate, register a pool, register a drep.
    ops =
      CertEffects.effects(%{type: :stake_registration, credential: cred()}, read(), @pp) ++
        CertEffects.effects(%{type: :stake_delegation, credential: cred(), pool: "p"}, read(), @pp) ++
        CertEffects.effects(
          %{type: :pool_registration, params: %{operator: "op1"} |> pool_params()},
          read(),
          @pp
        ) ++
        CertEffects.effects(%{type: :drep_registration, credential: {:key, <<9::224>>}, deposit: nil, anchor: nil}, read(), @pp)

    ChainStore.ledger_apply_block(<<300::256>>, 300, ops)
    refute snapshot() == before, "the block changed state"

    ChainStore.ledger_rollback(299)
    assert snapshot() == before, "rollback restored the exact prior state"
  end

  test "pool registration adds a deposit only when NEW (re-registration doesn't double-charge)" do
    p = pool_params(%{operator: "op2"})
    apply_cert(%{type: :pool_registration, params: p}, 100)
    assert ChainStore.ledger_read(:deposit, {:pool, "op2"}) == @pp.pool_deposit

    # re-register (params change, pool already exists) → NO new deposit
    apply_cert(%{type: :pool_registration, params: %{p | cost: 999}}, 110)
    assert ChainStore.ledger_read(:deposit, {:pool, "op2"}) == @pp.pool_deposit
  end

  # ---- MC/DC: one test per remaining effects/3 clause (test/TEST_STRATEGY.md). Each cert TYPE is
  # ---- a clause; a clause never driven is untested even at full line coverage. ----

  test "vote_delegation OVERWRITES vote_deleg; rollback restores the previous drep" do
    apply_cert(%{type: :stake_registration, credential: cred()}, 100)
    apply_cert(%{type: :vote_delegation, credential: cred(), drep: {:key, "d1"}}, 110)
    assert ChainStore.ledger_read(:vote_deleg, cred()) == {:key, "d1"}
    apply_cert(%{type: :vote_delegation, credential: cred(), drep: :abstain}, 120)
    assert ChainStore.ledger_read(:vote_deleg, cred()) == :abstain
    ChainStore.ledger_rollback(115)
    assert ChainStore.ledger_read(:vote_deleg, cred()) == {:key, "d1"}
  end

  test "stake_and_vote_delegation (10) sets BOTH delegations" do
    apply_cert(%{type: :stake_registration, credential: cred()}, 100)
    apply_cert(%{type: :stake_and_vote_delegation, credential: cred(), pool: "p", drep: :no_confidence}, 110)
    assert ChainStore.ledger_read(:stake_deleg, cred()) == "p"
    assert ChainStore.ledger_read(:vote_deleg, cred()) == :no_confidence
  end

  test "combined register+delegate certs (11/12/13) register (reward+deposit) AND delegate" do
    # 11: stake reg + pool delegate
    apply_cert(%{type: :stake_registration_and_delegation, credential: cred(), pool: "p", deposit: nil}, 100)
    assert ChainStore.ledger_read(:reward, cred()) == 0
    assert ChainStore.ledger_read(:deposit, {:cred, cred()}) == @pp.key_deposit
    assert ChainStore.ledger_read(:stake_deleg, cred()) == "p"

    c2 = {:key, <<2::224>>}
    apply_cert(%{type: :vote_registration_and_delegation, credential: c2, drep: {:key, "d"}, deposit: nil}, 110)
    assert ChainStore.ledger_read(:vote_deleg, c2) == {:key, "d"}

    c3 = {:key, <<3::224>>}
    apply_cert(%{type: :stake_vote_registration_and_delegation, credential: c3, pool: "p3", drep: :abstain, deposit: nil}, 120)
    assert ChainStore.ledger_read(:stake_deleg, c3) == "p3"
    assert ChainStore.ledger_read(:vote_deleg, c3) == :abstain
    assert ChainStore.ledger_read(:deposit, {:cred, c3}) == @pp.key_deposit
  end

  test "pool_retirement records the retiring epoch (overwrite)" do
    apply_cert(%{type: :pool_registration, params: pool_params(%{operator: "opR"})}, 100)
    apply_cert(%{type: :pool_retirement, pool: "opR", epoch: 42}, 110)
    assert ChainStore.ledger_read(:pool_retiring, "opR") == 42
  end

  test "drep_deregistration removes the drep and refunds (round-trips)" do
    d = {:key, <<8::224>>}
    apply_cert(%{type: :drep_registration, credential: d, deposit: nil, anchor: nil}, 100)
    assert ChainStore.ledger_read(:drep, d) != nil
    before = ChainStore.ledger_read(:deposit, {:drep, d})
    assert before == @pp.drep_deposit

    apply_cert(%{type: :drep_deregistration, credential: d}, 110)
    assert ChainStore.ledger_read(:drep, d) == nil
    assert (ChainStore.ledger_read(:deposit, {:drep, d}) || 0) == 0
  end

  test "drep_update overwrites the drep entry (no new deposit)" do
    d = {:key, <<9::224>>}
    apply_cert(%{type: :drep_registration, credential: d, deposit: nil, anchor: nil}, 100)
    dep = ChainStore.ledger_read(:deposit, {:drep, d})
    apply_cert(%{type: :drep_update, credential: d, anchor: %{url: "u", data_hash: "h"}}, 110)
    assert ChainStore.ledger_read(:drep, d) == %{anchor: %{url: "u", data_hash: "h"}}
    assert ChainStore.ledger_read(:deposit, {:drep, d}) == dep, "update must not add a deposit"
  end

  test "committee_hot_auth sets cc_hot; resignation removes it" do
    cold = {:key, "cold"}
    apply_cert(%{type: :committee_hot_auth, cold: cold, hot: {:key, "hot"}}, 100)
    assert ChainStore.ledger_read(:cc_hot, cold) == {:key, "hot"}
    apply_cert(%{type: :committee_resignation, cold: cold, anchor: nil}, 110)
    assert ChainStore.ledger_read(:cc_hot, cold) == nil
  end

  test "an unknown/unmodelled cert produces no ops (no state effect, no crash)" do
    assert CertEffects.effects(%{type: :unknown, tag: 99}, read(), @pp) == []
  end

  # a minimal valid pool_params map (only fields effects/rollback touch matter here)
  defp pool_params(m), do: Map.merge(%{operator: "op", cost: 0}, m)

  # A cheap full-state snapshot for the round-trip test (all ledger_state rows).
  defp snapshot do
    import Ecto.Query
    Cardamom.Store.Repo.all(from l in Cardamom.Store.LedgerState, select: {l.domain, l.key, l.value})
    |> Enum.sort()
  end

  # Silence "Delta unused" if the compiler frets — it's exercised transitively.
  @doc false
  def _touch, do: Delta
end
