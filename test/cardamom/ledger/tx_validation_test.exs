defmodule Cardamom.Ledger.TxValidationTest do
  @moduledoc """
  The INDEPENDENT, context-injected per-tx validation step (extracted from BlockHandler so
  the SAME rules run on mempool txs — [[project_tx_validation_independence]]). `run/3` takes
  a decoded tx, a `read` fun, and a `ctx` (protocol_major + pp), returning `{ops, results}`:
  the invertible ledger ops and the verdict check results, in spec order (PRE-CERT
  withdrawals then certs, Certs.lagda.md:632-633).

  ERA-GATING is the point of this change: rules keyed off the wrong version axis
  ([[reference_cardano_version_axes]]) false-reject on real data. The withdrawal
  vote-delegation precondition (`isKeyHash ⊆ dom voteDelegs`) is a CONWAY rule (protocol
  major ≥ 9); on Babbage (major 7–8) a key-hash withdrawal with NO vote delegation is
  perfectly valid and must NOT be flagged. This test pins both eras.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.TxValidation

  defp h(n), do: <<n::224>>
  defp k(n), do: {:key, h(n)}
  defp key_addr(n), do: <<0xE0, h(n)::binary>>

  defp reader(maps), do: fn domain, key -> get_in(maps, [domain, key]) end

  defp ctx(major),
    do: %{protocol_major: major, pp: %{key_deposit: 2_000_000, pool_deposit: 500_000_000}}

  defp results_for(rule, results), do: Enum.filter(results, &(elem(&1, 0) == rule))

  # ---- withdrawals: the era-gated vote-delegation precondition ----

  describe "withdrawal vote-delegation precondition is Conway-only (era-gated)" do
    test "CONWAY (major 9): key-hash withdrawal WITHOUT vote delegation → violation" do
      read = reader(%{reward: %{k(1) => 5_000}, vote_deleg: %{}})
      tx = %{txid: h(1), withdrawals: [{key_addr(1), 5_000}], certs: nil}

      {_ops, results} = TxValidation.run(tx, read, ctx(9))

      assert [{:withdrawal_vote_delegated, {:violation, _}, _}] =
               results_for(:withdrawal_vote_delegated, results)
    end

    test "BABBAGE (major 8): SAME tx is fine — the rule doesn't exist yet, so PASS" do
      read = reader(%{reward: %{k(1) => 5_000}, vote_deleg: %{}})
      tx = %{txid: h(1), withdrawals: [{key_addr(1), 5_000}], certs: nil}

      {ops, results} = TxValidation.run(tx, read, ctx(8))

      assert [{:withdrawal_vote_delegated, :pass, _}] =
               results_for(:withdrawal_vote_delegated, results)

      # the zeroing EFFECT still applies in both eras (it's the ledger update, not the check)
      assert {:set, :reward, k(1), 5_000, 0} in ops
    end

    test "the full-balance oracle is era-INDEPENDENT (both eras flag a mismatch)" do
      read = reader(%{reward: %{k(1) => 4_999}, vote_deleg: %{k(1) => :drep_x}})
      tx = %{txid: h(1), withdrawals: [{key_addr(1), 5_000}], certs: nil}

      for major <- [8, 9] do
        {_ops, results} = TxValidation.run(tx, read, ctx(major))

        assert [{:withdrawal_full_balance, {:violation, %{withdrawn: 5_000, our_balance: 4_999}}, _}] =
                 results_for(:withdrawal_full_balance, results)
      end
    end
  end

  # ---- spec order + cert effects still produced ----

  test "PRE-CERT order: withdrawal ops precede this tx's cert ops" do
    read = reader(%{reward: %{k(1) => 100}, vote_deleg: %{k(1) => :d}})
    # a stake_registration cert (tag 7, explicit deposit) after a withdrawal
    tx = %{txid: h(1), withdrawals: [{key_addr(1), 100}], certs: [[7, [0, h(2)], 2_000_000]]}

    {ops, _results} = TxValidation.run(tx, read, ctx(9))

    wdrl_idx = Enum.find_index(ops, &match?({:set, :reward, {:key, _}, _, 0}, &1))
    assert is_integer(wdrl_idx), "withdrawal zeroing op present"
    # a cert op exists after it (deposit accrual) — certs follow withdrawals
    assert length(ops) > wdrl_idx + 1
  end

  test "results carry the txid for every check (verdict attribution)" do
    read = reader(%{reward: %{k(1) => 5_000}, vote_deleg: %{k(1) => :d}})
    tx = %{txid: h(42), withdrawals: [{key_addr(1), 5_000}], certs: nil}

    {_ops, results} = TxValidation.run(tx, read, ctx(9))
    assert Enum.all?(results, fn {_r, _o, opts} -> Keyword.get(opts, :txid) == h(42) end)
  end

  test "a tx with neither withdrawals nor certs yields no ops and no results" do
    read = reader(%{})
    assert TxValidation.run(%{txid: h(1), withdrawals: [], certs: nil}, read, ctx(9)) == {[], []}
  end
end
