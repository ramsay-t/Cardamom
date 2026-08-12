defmodule Cardamom.Ledger.CertPreconditions do
  @moduledoc """
  Phase-1 CERT PRECONDITIONS (Conway CERTS / DELEG / POOL rules) — the checks that pair with the
  cert EFFECTS in `Cardamom.Ledger.CertEffects` (we apply the state change; here we check it was
  ALLOWED). Verdict tuples against the injected `read` (`(domain, key) -> value | nil`), the same
  reader the effects use.

  Checked (what our derived state can decide):
    * `:cert_stake_registration`   — the credential must NOT already be registered.
    * `:cert_stake_deregistration` — the credential MUST already be registered.
    * `:cert_delegation_target`    — a stake delegation's target pool MUST be registered.
    * `:cert_pool_retirement`      — the retiring pool MUST be registered.

  Registration presence: a registered stake credential has a `:reward` entry (registration
  creates it at 0, deregistration removes it), so `read.(:reward, cred) != nil` ⟺ registered.
  Pool registration: `read.(:pool, pool) != nil`.

  Cert types without a precondition we can decide (delegations to a DRep, DRep/committee certs,
  pool (re-)registration — a legal update, not a gated precondition) emit NO result — silence,
  never a false pass. As with the other oracles, we assert only what we can compute; the rest is
  left to later rules (e.g. dereg's zero-balance requirement, once we track it precisely).
  """

  alias Cardamom.Ledger.Conway.Cert

  @doc "Precondition results for ONE decoded cert (a `%{type: …}` map). `[]` when none apply."
  def check(%{type: :stake_registration, credential: cred}, read) do
    if read.(:reward, cred) == nil,
      do: [{:cert_stake_registration, :pass, []}],
      else: [{:cert_stake_registration, {:violation, %{credential: inspect(cred), reason: :already_registered}}, []}]
  end

  def check(%{type: :stake_deregistration, credential: cred}, read) do
    if read.(:reward, cred) != nil,
      do: [{:cert_stake_deregistration, :pass, []}],
      else: [{:cert_stake_deregistration, {:violation, %{credential: inspect(cred), reason: :not_registered}}, []}]
  end

  def check(%{type: :stake_delegation, pool: pool}, read), do: [delegation_target(pool, read)]

  # Combined reg+delegation certs also delegate — check their pool target.
  def check(%{type: :stake_registration_and_delegation, pool: pool}, read), do: [delegation_target(pool, read)]
  def check(%{type: :stake_vote_registration_and_delegation, pool: pool}, read), do: [delegation_target(pool, read)]

  def check(%{type: :pool_retirement, pool: pool}, read) do
    if read.(:pool, pool) != nil,
      do: [{:cert_pool_retirement, :pass, []}],
      else: [{:cert_pool_retirement, {:violation, %{pool: hex(pool), reason: :pool_not_registered}}, []}]
  end

  # Everything else: no precondition we decide here.
  def check(_cert, _read), do: []

  defp delegation_target(pool, read) do
    if read.(:pool, pool) != nil,
      do: {:cert_delegation_target, :pass, []},
      else: {:cert_delegation_target, {:violation, %{pool: hex(pool), reason: :pool_not_registered}}, []}
  end

  @doc """
  Precondition results for a RAW certs list (as carried on a tx, body key 4) — decodes with
  `Cardamom.Ledger.Conway.Cert` and stamps each result with `opts[:txid]`. Certs apply in order
  and can register a target within the same tx; callers wanting same-tx visibility should pass a
  read-through overlay (as `TxValidation` does for effects).
  """
  def check_all(certs, read, opts \\ []) do
    txid = Keyword.get(opts, :txid)

    certs
    |> Cert.decode_all()
    |> Enum.flat_map(&check(&1, read))
    |> Enum.map(fn {rule, outcome, o} -> {rule, outcome, Keyword.put(o, :txid, txid)} end)
  end

  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)
  defp hex(other), do: inspect(other)
end
