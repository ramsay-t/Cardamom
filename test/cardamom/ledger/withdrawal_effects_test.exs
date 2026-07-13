defmodule Cardamom.Ledger.WithdrawalEffectsTest do
  @moduledoc """
  PRE-CERT withdrawals (Certs.lagda.md:596-607): the zeroing EFFECT and the WITHDRAWAL ORACLE —
  a network-accepted withdrawal must equal our derived balance exactly, and a key-hash withdrawer
  must have vote-delegated. Divergences are telemetry signals, never rejections; the effect
  applies regardless (self-healing). Telemetry is captured filtered to THIS test's handler id
  (handle the interleaving, don't serialise it).
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
  defp capture_divergences(fun) do
    id = make_ref()
    me = self()

    :telemetry.attach(
      id,
      [:cardamom, :ledger, :divergence],
      fn _event, _meas, meta, _cfg -> send(me, {:divergence, id, meta}) end,
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

  test "a full-balance withdrawal from a vote-delegated key cred: zeroing op, NO divergence" do
    read = reader(%{reward: %{k(1) => 5_000}, vote_deleg: %{k(1) => :drep_x}})

    divergences =
      capture_divergences(fn ->
        assert WithdrawalEffects.effects([{key_addr(1), 5_000}], read) ==
                 [{:set, :reward, k(1), 5_000, 0}]
      end)

    assert divergences == []
  end

  test "ORACLE: amount ≠ our balance → :withdrawal_balance_mismatch, effect still applied" do
    read = reader(%{reward: %{k(1) => 4_999}, vote_deleg: %{k(1) => :drep_x}})

    divergences =
      capture_divergences(fn ->
        assert WithdrawalEffects.effects([{key_addr(1), 5_000}], read) ==
                 [{:set, :reward, k(1), 4_999, 0}]
      end)

    assert [%{check: :withdrawal_balance_mismatch, withdrawn: 5_000, our_balance: 4_999}] =
             divergences
  end

  test "ORACLE MC/DC: account we don't know at all → mismatch (nil balance), zeroed from nil" do
    read = reader(%{reward: %{}, vote_deleg: %{k(1) => :drep_x}})

    divergences =
      capture_divergences(fn ->
        assert WithdrawalEffects.effects([{key_addr(1), 5_000}], read) ==
                 [{:set, :reward, k(1), nil, 0}]
      end)

    assert [%{check: :withdrawal_balance_mismatch, our_balance: nil}] = divergences
  end

  test "ORACLE MC/DC: key-hash cred WITHOUT vote delegation → :withdrawal_without_vote_delegation" do
    read = reader(%{reward: %{k(1) => 5_000}, vote_deleg: %{}})

    divergences =
      capture_divergences(fn -> WithdrawalEffects.effects([{key_addr(1), 5_000}], read) end)

    assert [%{check: :withdrawal_without_vote_delegation}] = divergences
  end

  test "ORACLE MC/DC: SCRIPT cred without vote delegation is EXEMPT (filter isKeyHash)" do
    read = reader(%{reward: %{{:script, h(1)} => 5_000}, vote_deleg: %{}})

    divergences =
      capture_divergences(fn ->
        assert WithdrawalEffects.effects([{script_addr(1), 5_000}], read) ==
                 [{:set, :reward, {:script, h(1)}, 5_000, 0}]
      end)

    assert divergences == []
  end

  test "MC/DC: unparseable reward address → signal, no op, no crash" do
    read = reader(%{reward: %{}, vote_deleg: %{}})

    divergences =
      capture_divergences(fn ->
        assert WithdrawalEffects.effects([{<<0xE0, 1, 2>>, 100}], read) == []
      end)

    assert [%{check: :withdrawal_address_unparseable}] = divergences
  end

  test "MC/DC: malformed entry / non-list input → nothing, defensively" do
    read = reader(%{})
    assert WithdrawalEffects.effects([:junk], read) |> Enum.empty?()
    assert WithdrawalEffects.effects(nil, read) == []
  end

  test "same-block visibility: read through an earlier op sees the zeroed balance" do
    # After tx1 withdraws, tx2's withdrawal of the SAME account sees 0 — a second full
    # withdrawal of 0 is consistent (0 == 0), a non-zero one diverges.
    base = reader(%{reward: %{k(1) => 5_000}, vote_deleg: %{k(1) => :drep_x}})
    ops1 = WithdrawalEffects.effects([{key_addr(1), 5_000}], base)
    overlay = Cardamom.Ledger.Delta.read_through(ops1, base)

    divergences =
      capture_divergences(fn ->
        assert WithdrawalEffects.effects([{key_addr(1), 0}], overlay) ==
                 [{:set, :reward, k(1), 0, 0}]
      end)

    assert divergences == []
  end
end
