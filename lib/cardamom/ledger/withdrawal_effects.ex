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

  Per the observer stance (see Cardamom.Ledger.Conformance): a failed precondition is a
  DIVERGENCE SIGNAL (log + telemetry), never a rejection — and the zeroing effect is still
  applied, which matches the network's post-tx state and lets our balance self-heal.

  NOT here: PRE-CERT's DRep activity refresh (`refreshedDReps`) — it needs the tx's VOTES, which
  we don't decode yet (the governance gap; goes with gov-action tracking).
  """

  require Logger

  alias Cardamom.Ledger.Address

  @doc """
  Ops + oracle for one decoded tx's withdrawals (`[{reward_addr_bytes, coin}]`). `read` is the
  usual `(domain, key) -> value | nil` fun (pass the block's read-through overlay so same-block
  effects are visible). Returns the list of `{:set, :reward, cred, old, 0}` ops.
  """
  def effects(withdrawals, read) when is_list(withdrawals) and is_function(read, 2) do
    Enum.flat_map(withdrawals, fn
      {addr, amount} when is_binary(addr) and is_integer(amount) ->
        case Address.stake_credential(addr) do
          nil ->
            # Not a parseable reward address — the network wouldn't have accepted it, so this is
            # OUR decode gap, not a ledger event. Surface it; no op.
            diverge(:withdrawal_address_unparseable, %{address: hex(addr)})
            []

          cred ->
            balance = read.(:reward, cred)
            check_full_balance(cred, amount, balance)
            check_vote_delegated(cred, read)
            # the effect: constMap wdrlCreds 0 ∪ˡ rewards — the account is zeroed.
            [{:set, :reward, cred, balance, 0}]
        end

      other ->
        diverge(:withdrawal_malformed, %{entry: inspect(other)})
        []
    end)
  end

  def effects(_not_a_list, _read), do: []

  # `(stake cred, amount) ∈ rewards` — amount must equal the FULL balance we derived.
  defp check_full_balance(_cred, amount, balance) when amount == balance, do: :ok

  defp check_full_balance(cred, amount, balance) do
    diverge(:withdrawal_balance_mismatch, %{
      credential: inspect(cred),
      withdrawn: amount,
      our_balance: balance
    })
  end

  # `filter isKeyHash wdrlCreds ⊆ dom voteDelegs` — key-hash creds must have vote-delegated.
  defp check_vote_delegated({:script, _}, _read), do: :ok

  defp check_vote_delegated({:key, _} = cred, read) do
    if read.(:vote_deleg, cred) == nil do
      diverge(:withdrawal_without_vote_delegation, %{credential: inspect(cred)})
    end
  end

  defp diverge(check, detail) do
    Logger.warning("ledger conformance DIVERGENCE (#{check}): #{inspect(detail)}")
    :telemetry.execute([:cardamom, :ledger, :divergence], %{diff: 1}, Map.put(detail, :check, check))
    :ok
  end

  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)
end
