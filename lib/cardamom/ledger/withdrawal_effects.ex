defmodule Cardamom.Ledger.WithdrawalEffects do
  @moduledoc """
  Withdrawal handling — the spec's PRE-CERT rule (Certs.lagda.md:596-607), which runs at the
  START of a tx's CERTS processing (before any cert): it CHECKS the withdrawals and ZEROES the
  withdrawn reward accounts (`constMap wdrlCreds 0 ∪ˡ rewards`).

  This is both a Tier-a EFFECT and the WITHDRAWAL CONFORMANCE ORACLE — the sharpest divergence
  check a follower has. The rule's preconditions are facts the network asserted by accepting the
  tx:

    * `mapˢ (map₁ stake) (wdrls ˢ) ⊆ rewards ˢ` — each withdrawal amount EQUALS the account's
      entire balance (Cardano withdrawals are all-or-nothing). If the network accepted an amount
      our ledger says the account doesn't hold, OUR reward computation has drifted — this is
      precisely the check the whole Tier-b engine is validated by.
    * `filter isKeyHash wdrlCreds ⊆ dom voteDelegs` — a key-hash withdrawer must have delegated
      its VOTE (Conway: no reward withdrawal without vote delegation). Script creds are exempt.

  VERDICT PLUMBING (the validation-gate architecture, see `Cardamom.Ledger.Verdict`): each check
  RETURNS a result — `effects/2` yields `{ops, results}` and the BlockHandler renders the block's
  verdict from the results BEFORE committing the ops. A violation therefore REJECTS the block
  (stop-and-fix, expected never to fire on chain load) rather than the old self-heal-and-log.
  This module itself stays judgment-free: it never raises and still emits the per-check
  divergence telemetry at the point of detection (the existing event spine).

  NOT here: PRE-CERT's DRep activity refresh (`refreshedDReps`) — it needs the tx's VOTES, which
  we don't decode yet (the governance gap; goes with gov-action tracking).
  """

  require Logger

  alias Cardamom.Ledger.Address

  @doc """
  Ops + check results for one decoded tx's withdrawals (`[{reward_addr_bytes, coin}]`). `read`
  is the usual `(domain, key) -> value | nil` fun (pass the block's read-through overlay so
  same-block effects are visible). Returns `{ops, results}`:

    * `ops` — the `{:set, :reward, cred, old, 0}` zeroing ops (`constMap wdrlCreds 0 ∪ˡ rewards`),
    * `results` — `{rule, outcome, opts}` tuples for `Cardamom.Ledger.Verdict.add_all/2`.

  An unparseable/malformed withdrawal yields a `:withdrawal_decodable` violation and NO op: the
  network accepted the tx, so failing to decode it means our derived state would silently omit
  the zeroing — exactly a stop-and-fix condition.
  """
  def effects(withdrawals, read) when is_list(withdrawals) and is_function(read, 2) do
    Enum.reduce(withdrawals, {[], []}, fn entry, {ops, results} ->
      case entry do
        {addr, amount} when is_binary(addr) and is_integer(amount) ->
          case Address.stake_credential(addr) do
            nil ->
              detail = %{address: hex(addr)}
              diverge(:withdrawal_address_unparseable, detail)
              {ops, results ++ [{:withdrawal_decodable, {:violation, detail}, []}]}

            cred ->
              balance = read.(:reward, cred)

              # the effect: constMap wdrlCreds 0 ∪ˡ rewards — the account is zeroed. The op is
              # built even when a check violates (self-describing; the gate decides its fate).
              {ops ++ [{:set, :reward, cred, balance, 0}],
               results ++ [check_full_balance(cred, amount, balance), check_vote_delegated(cred, read)]}
          end

        other ->
          detail = %{entry: inspect(other)}
          diverge(:withdrawal_malformed, detail)
          {ops, results ++ [{:withdrawal_decodable, {:violation, detail}, []}]}
      end
    end)
  end

  def effects(_not_a_list, _read), do: {[], []}

  # `(stake cred, amount) ∈ rewards` — amount must equal the FULL balance we derived.
  defp check_full_balance(_cred, amount, balance) when amount == balance,
    do: {:withdrawal_full_balance, :pass, []}

  defp check_full_balance(cred, amount, balance) do
    detail = %{credential: inspect(cred), withdrawn: amount, our_balance: balance}
    diverge(:withdrawal_balance_mismatch, detail)
    {:withdrawal_full_balance, {:violation, detail}, []}
  end

  # `filter isKeyHash wdrlCreds ⊆ dom voteDelegs` — key-hash creds must have vote-delegated;
  # script creds are outside the rule's domain (vacuous pass).
  defp check_vote_delegated({:script, _}, _read), do: {:withdrawal_vote_delegated, :pass, []}

  defp check_vote_delegated({:key, _} = cred, read) do
    if read.(:vote_deleg, cred) == nil do
      detail = %{credential: inspect(cred)}
      diverge(:withdrawal_without_vote_delegation, detail)
      {:withdrawal_vote_delegated, {:violation, detail}, []}
    else
      {:withdrawal_vote_delegated, :pass, []}
    end
  end

  defp diverge(check, detail) do
    Logger.warning("ledger conformance DIVERGENCE (#{check}): #{inspect(detail)}")
    :telemetry.execute([:cardamom, :ledger, :divergence], %{diff: 1}, Map.put(detail, :check, check))
    :ok
  end

  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)
end
