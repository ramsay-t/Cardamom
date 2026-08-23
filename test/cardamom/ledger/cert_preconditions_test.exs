defmodule Cardamom.Ledger.CertPreconditionsTest do
  @moduledoc """
  Phase-1 CERT PRECONDITIONS (Conway CERTS/DELEG rules) — the checks that pair with the cert
  EFFECTS we already apply. Each a verdict tuple against the injected `read` (registration &
  pool state). We check what our derived state can decide; unknowable ones are honest skips.

    * stake_registration     — the credential must NOT already be registered.
    * stake_deregistration   — the credential MUST already be registered.
    * stake_delegation       — the target pool MUST be registered.
    * pool_retirement        — the pool MUST be registered.

  A registered stake credential has a `:reward` entry (registration creates it, dereg removes it),
  so `read.(:reward, cred)` presence = registered. Pool registration = `read.(:pool, pool)`.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.CertPreconditions, as: P

  defp kh(n), do: <<n::224>>
  defp cred(n), do: {:key, kh(n)}
  defp reader(m), do: fn dom, key -> get_in(m, [dom, key]) end
  defp r(rule, results), do: Enum.find(results, &(elem(&1, 0) == rule))

  test "stake_registration: fresh credential passes; already-registered violates" do
    fresh = reader(%{reward: %{}})
    dup = reader(%{reward: %{cred(1) => 0}})

    cert = %{type: :stake_registration, credential: cred(1)}
    assert {:cert_stake_registration, :pass, _} = r(:cert_stake_registration, P.check(cert, fresh))
    assert {:cert_stake_registration, {:violation, _}, _} = r(:cert_stake_registration, P.check(cert, dup))
  end

  test "stake_deregistration: registered passes; unregistered violates" do
    reg = reader(%{reward: %{cred(1) => 0}})
    unreg = reader(%{reward: %{}})

    cert = %{type: :stake_deregistration, credential: cred(1)}
    assert {:cert_stake_deregistration, :pass, _} = r(:cert_stake_deregistration, P.check(cert, reg))
    assert {:cert_stake_deregistration, {:violation, _}, _} = r(:cert_stake_deregistration, P.check(cert, unreg))
  end

  test "stake_delegation: target pool registered passes; unknown pool violates" do
    known = reader(%{pool: %{kh(9) => %{}}})
    unknown = reader(%{pool: %{}})

    cert = %{type: :stake_delegation, credential: cred(1), pool: kh(9)}
    assert {:cert_delegation_target, :pass, _} = r(:cert_delegation_target, P.check(cert, known))
    assert {:cert_delegation_target, {:violation, _}, _} = r(:cert_delegation_target, P.check(cert, unknown))
  end

  test "pool_retirement: registered pool passes; unknown violates" do
    known = reader(%{pool: %{kh(9) => %{}}})
    cert = %{type: :pool_retirement, pool: kh(9), epoch: 100}
    assert {:cert_pool_retirement, :pass, _} = r(:cert_pool_retirement, P.check(cert, known))

    unknown = reader(%{pool: %{}})
    assert {:cert_pool_retirement, {:violation, _}, _} = r(:cert_pool_retirement, P.check(cert, unknown))
  end

  test "a cert type with no precondition we check yields no result (not a false pass)" do
    cert = %{type: :vote_delegation, credential: cred(1), drep: :abstain}
    assert P.check(cert, reader(%{})) == []
  end

  test "pool_registration always OK-to-check as (re-)registration: no violation" do
    # pool re-registration is a legal update, not a precondition failure — no result emitted
    cert = %{type: :pool_registration, params: []}
    assert P.check(cert, reader(%{})) == []
  end

  test "check_all folds a RAW cert list (as on a tx), stamping the txid" do
    read = reader(%{reward: %{}})
    # raw stake_registration (tag 0) of a key credential ([0, keyhash28])
    certs = [[0, [0, %CBOR.Tag{tag: :bytes, value: kh(1)}]]]
    results = P.check_all(certs, read, txid: <<5::256>>)
    assert [{:cert_stake_registration, :pass, _}] = results
    assert Enum.all?(results, fn {_r, _o, opts} -> Keyword.get(opts, :txid) == <<5::256>> end)
  end

  # MC/DC per clause: the COMBINED reg+delegation certs also check the pool target.
  test "combined reg+delegation certs check their delegation target pool" do
    known = reader(%{pool: %{kh(9) => %{}}})
    unknown = reader(%{pool: %{}})

    for type <- [:stake_registration_and_delegation, :stake_vote_registration_and_delegation] do
      cert = %{type: type, credential: cred(1), pool: kh(9)}
      assert [{:cert_delegation_target, :pass, _}] = P.check(cert, known)
      assert [{:cert_delegation_target, {:violation, _}, _}] = P.check(cert, unknown)
    end
  end

  test "pool_retirement of an unknown pool violates (the violation arm)" do
    cert = %{type: :pool_retirement, pool: kh(9), epoch: 100}
    assert [{:cert_pool_retirement, {:violation, %{reason: :pool_not_registered}}, _}] =
             P.check(cert, reader(%{pool: %{}}))
  end
end
