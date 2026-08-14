defmodule Cardamom.Ledger.WithdrawalEffectsTest do
  @moduledoc """
  PRE-CERT withdrawals (Certs.lagda.md:596-607): the zeroing EFFECT and the WITHDRAWAL ORACLE —
  a network-accepted withdrawal must equal our derived balance exactly, and a key-hash withdrawer
  must have vote-delegated. Checks RETURN results for the block verdict (the validation-gate
  architecture): `effects/2 → {ops, results}`; a violation rejects the block upstream. The
  per-check divergence telemetry still fires at detection; it is captured here filtered to THIS
  test's handler id (handle the interleaving, don't serialise it).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.WithdrawalEffects

  defp h(n), do: <<n::224>>
  defp k(n), do: {:key, h(n)}
  # reward addresses: type 14 (key) / 15 (script), network 0
  defp key_addr(n), do: <<0xE0, h(n)::binary>>
  defp script_addr(n), do: <<0xF0, h(n)::binary>>

  # A read fun over fixed domain maps.
  defp reader(maps) do
    fn domain, key -> get_in(maps, [domain, key]) end
  end

  # Capture [:cardamom, :ledger, :divergence] events fired during fun; returns their metadata.
  # The telemetry handler is GLOBAL, so under `async: true` a CONCURRENT test's divergence would
  # leak in. Filter by PROCESS IDENTITY: a telemetry handler runs SYNCHRONOUSLY in the process
  # that called :telemetry.execute, and OUR divergences are emitted by WithdrawalEffects running
  # in THIS test's process — so `self() == me` inside the handler is true for our events and false
  # for any concurrent test's. Exact identity, not a fragile marker match (handle the interleaving
  # by identity, don't serialise it away — the project's own thesis applied to tests). `marker` is
  # retained for the unparseable-address case whose event carries no k(1)-shaped metadata but is
  # still emitted in-process (so identity alone suffices; marker is now unused but kept harmless).
  defp capture_divergences(fun, _marker \\ nil) do
    id = make_ref()
    me = self()

    :telemetry.attach(
      id,
      [:cardamom, :ledger, :divergence],
      fn _event, _meas, meta, _cfg ->
        if self() == me, do: send(me, {:divergence, id, meta})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect_divergences(id, [])
  end

  defp collect_divergences(id, acc) do
    receive do
      {:divergence, ^id, meta} -> collect_divergences(id, [meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a full-balance withdrawal from a vote-delegated key cred: zeroing op, both checks PASS" do
    read = reader(%{reward: %{k(1) => 5_000}, vote_deleg: %{k(1) => :drep_x}})

    divergences =
      capture_divergences(fn ->
        assert WithdrawalEffects.effects([{key_addr(1), 5_000}], read) ==
                 {[{:set, :reward, k(1), 5_000, 0}],
                  [
                    {:withdrawal_full_balance, :pass, []},
                    {:withdrawal_vote_delegated, :pass, []}
                  ]}
      end)

    assert divergences == []
  end

  test "ORACLE: amount ≠ our balance → :withdrawal_full_balance VIOLATION, op still built" do
    read = reader(%{reward: %{k(1) => 4_999}, vote_deleg: %{k(1) => :drep_x}})
    cred = k(1)

    divergences =
      capture_divergences(fn ->
        assert {[{:set, :reward, ^cred, 4_999, 0}], results} =
                 WithdrawalEffects.effects([{key_addr(1), 5_000}], read)

        assert [
                 {:withdrawal_full_balance, {:violation, %{withdrawn: 5_000, our_balance: 4_999}}, []},
                 {:withdrawal_vote_delegated, :pass, []}
               ] = results
      end)

    # find THIS test's own divergence (a concurrent async test may share the k(1) credential and
    # emit a different check into the global telemetry surface — assert presence, not sole-ness)
    assert %{check: :withdrawal_balance_mismatch, withdrawn: 5_000, our_balance: 4_999} =
             Enum.find(divergences, &(&1.check == :withdrawal_balance_mismatch))
  end

  test "ORACLE MC/DC: account we don't know at all → violation (nil balance), zeroed from nil" do
    read = reader(%{reward: %{}, vote_deleg: %{k(1) => :drep_x}})
    cred = k(1)

    divergences =
      capture_divergences(fn ->
        assert {[{:set, :reward, ^cred, nil, 0}], results} =
                 WithdrawalEffects.effects([{key_addr(1), 5_000}], read)

        assert [{:withdrawal_full_balance, {:violation, %{our_balance: nil}}, []} | _] = results
      end)

    assert %{check: :withdrawal_balance_mismatch, our_balance: nil} =
             Enum.find(divergences, &(&1.check == :withdrawal_balance_mismatch))
  end

  test "ORACLE MC/DC: key-hash cred WITHOUT vote delegation → :withdrawal_vote_delegated violation" do
    read = reader(%{reward: %{k(1) => 5_000}, vote_deleg: %{}})

    divergences =
      capture_divergences(fn ->
        assert {_ops, results} = WithdrawalEffects.effects([{key_addr(1), 5_000}], read)

        assert [
                 {:withdrawal_full_balance, :pass, []},
                 {:withdrawal_vote_delegated, {:violation, _}, []}
               ] = results
      end)

    assert %{check: :withdrawal_without_vote_delegation} =
             Enum.find(divergences, &(&1.check == :withdrawal_without_vote_delegation))
  end

  test "ORACLE MC/DC: SCRIPT cred without vote delegation is EXEMPT (filter isKeyHash)" do
    read = reader(%{reward: %{{:script, h(1)} => 5_000}, vote_deleg: %{}})

    divergences =
      capture_divergences(fn ->
        assert WithdrawalEffects.effects([{script_addr(1), 5_000}], read) ==
                 {[{:set, :reward, {:script, h(1)}, 5_000, 0}],
                  [
                    {:withdrawal_full_balance, :pass, []},
                    {:withdrawal_vote_delegated, :pass, []}
                  ]}
      end)

    assert divergences == []
  end

  test "MC/DC: unparseable reward address → :withdrawal_decodable violation, NO op, no crash" do
    read = reader(%{reward: %{}, vote_deleg: %{}})

    divergences =
      capture_divergences(
        fn ->
          assert {[], [{:withdrawal_decodable, {:violation, %{address: _}}, []}]} =
                   WithdrawalEffects.effects([{<<0xE0, 1, 2>>, 100}], read)
        end,
        "e00102"
      )

    assert [%{check: :withdrawal_address_unparseable}] = divergences
  end

  test "MC/DC: malformed entry → decodable violation; non-list input → nothing, defensively" do
    read = reader(%{})

    assert {[], [{:withdrawal_decodable, {:violation, _}, []}]} =
             WithdrawalEffects.effects([:junk], read)

    assert WithdrawalEffects.effects(nil, read) == {[], []}
  end

  test "same-block visibility: read through an earlier op sees the zeroed balance" do
    # After tx1 withdraws, tx2's withdrawal of the SAME account sees 0 — a second full
    # withdrawal of 0 is consistent (0 == 0), a non-zero one diverges.
    base = reader(%{reward: %{k(1) => 5_000}, vote_deleg: %{k(1) => :drep_x}})
    cred = k(1)
    {ops1, _results1} = WithdrawalEffects.effects([{key_addr(1), 5_000}], base)
    overlay = Cardamom.Ledger.Delta.read_through(ops1, base)

    divergences =
      capture_divergences(fn ->
        assert {[{:set, :reward, ^cred, 0, 0}], results} =
                 WithdrawalEffects.effects([{key_addr(1), 0}], overlay)

        assert [{:withdrawal_full_balance, :pass, []} | _] = results
      end)

    assert divergences == []
  end
end
