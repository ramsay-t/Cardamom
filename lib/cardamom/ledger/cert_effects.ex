defmodule Cardamom.Ledger.CertEffects do
  @moduledoc """
  Map a decoded Conway certificate to its INVERTIBLE ledger-state ops (Cardamom.Ledger.Delta).
  This is the state-effect half of cert handling — the "actual design work" (decoding was crypto-
  free typing). Authoritative source: formal-ledger Certs.lagda.md (DELEG/POOL/GOVCERT rules) +
  Conformance/Certs.lagda.md updateCertDeposit; classification per the extracted cert table.

  WHY A STATE READER: overwrite/remove ops must CAPTURE the displaced OLD value to be invertible
  (Delta rule). So `effects/3` takes a `read` fun `(domain, key) -> current_value | nil` and emits
  {:set, .., old, new} / {:del, .., old} with the real prior value read from current state.

  DEPOSITS: a registration adds a deposit; the amount is either STATED in the cert (Conway tags
  7/8/11/12/13/16/17) or from a PROTOCOL PARAM (deprecated tags 0/1, pool tag 3). `pp` supplies
  key_deposit/pool_deposit/drep_deposit; keyed off PROTOCOL MAJOR elsewhere (version-axes caveat).
  A refund (deregistration) is the inverse — captured by reading the stored deposit.

  REWARD ACCOUNT: registration creates a rewards entry (balance 0 until Tier b computes rewards);
  deregistration removes it. Represented in the :reward domain.
  """

  @doc """
  Ops for one decoded cert. `read.(domain, key)` returns the current value (or nil). `pp` is a map
  of protocol-param deposits: %{key_deposit:, pool_deposit:, drep_deposit:}. Returns a list of
  Delta ops (possibly empty for certs with no Tier-a state effect we model).
  """
  @spec effects(map(), (atom(), term() -> term()), map()) :: [tuple()]
  def effects(cert, read, pp)

  # ---- stake registration (0 param-deposit, 7 stated-deposit) ----
  def effects(%{type: :stake_registration} = c, _read, pp) do
    dep = Map.get(c, :deposit) || pp.key_deposit
    cred = c.credential
    [{:put, :reward, cred, 0}, {:put, :deposit, {:cred, cred}, dep}]
  end

  # ---- stake deregistration (1 param, 8 stated) — refund + remove reward + drop delegations ----
  def effects(%{type: :stake_deregistration} = c, read, _pp) do
    cred = c.credential
    dep = read.(:deposit, {:cred, cred}) || Map.get(c, :refund) || 0
    reward_old = read.(:reward, cred)
    stake_old = read.(:stake_deleg, cred)
    vote_old = read.(:vote_deleg, cred)

    []
    |> del_if(stake_old, :stake_deleg, cred)
    |> del_if(vote_old, :vote_deleg, cred)
    |> del_if(reward_old, :reward, cred)
    |> Kernel.++([{:del, :deposit, {:cred, cred}, dep}])
  end

  # ---- stake delegation (2) — OVERWRITE stake_deleg (capture old) ----
  def effects(%{type: :stake_delegation, credential: cred, pool: pool}, read, _pp) do
    [set_op(:stake_deleg, cred, read, pool)]
  end

  # ---- vote delegation (9) — OVERWRITE vote_deleg ----
  def effects(%{type: :vote_delegation, credential: cred, drep: drep}, read, _pp) do
    [set_op(:vote_deleg, cred, read, drep)]
  end

  # ---- combined (10) stake+vote delegation ----
  def effects(%{type: :stake_and_vote_delegation, credential: cred, pool: pool, drep: drep}, read, _pp) do
    [set_op(:stake_deleg, cred, read, pool), set_op(:vote_deleg, cred, read, drep)]
  end

  # ---- combined register+delegate (11/12/13) — register (reward+deposit) THEN delegate ----
  def effects(%{type: :stake_registration_and_delegation} = c, read, pp) do
    reg(c, pp) ++ [set_op(:stake_deleg, c.credential, read, c.pool)]
  end

  def effects(%{type: :vote_registration_and_delegation} = c, read, pp) do
    reg(c, pp) ++ [set_op(:vote_deleg, c.credential, read, c.drep)]
  end

  def effects(%{type: :stake_vote_registration_and_delegation} = c, read, pp) do
    reg(c, pp) ++
      [set_op(:stake_deleg, c.credential, read, c.pool), set_op(:vote_deleg, c.credential, read, c.drep)]
  end

  # ---- pool registration (3) — OVERWRITE pool params (capture old), add deposit only if NEW ----
  def effects(%{type: :pool_registration, params: params}, read, pp) do
    pool = params.operator
    old = read.(:pool, pool)
    deposit_ops = if old == nil, do: [{:put, :deposit, {:pool, pool}, pp.pool_deposit}], else: []
    [{:set, :pool, pool, old, params} | deposit_ops]
  end

  # ---- pool retirement (4) — OVERWRITE retiring[pool] with the epoch (capture old) ----
  def effects(%{type: :pool_retirement, pool: pool, epoch: epoch}, read, _pp) do
    [set_op(:pool_retiring, pool, read, epoch)]
  end

  # ---- DRep registration (16) — put drep (new) or update (existing); deposit only if new ----
  def effects(%{type: :drep_registration} = c, read, pp) do
    cred = c.credential
    old = read.(:drep, cred)
    dep = Map.get(c, :deposit) || pp.drep_deposit

    if old == nil do
      [{:put, :drep, cred, drep_entry(c)}, {:put, :deposit, {:drep, cred}, dep}]
    else
      [{:set, :drep, cred, old, drep_entry(c)}]
    end
  end

  # ---- DRep deregistration (17) — remove drep + refund ----
  def effects(%{type: :drep_deregistration} = c, read, _pp) do
    cred = c.credential
    old = read.(:drep, cred)
    dep = read.(:deposit, {:drep, cred}) || Map.get(c, :refund) || 0
    del_if([], old, :drep, cred) ++ [{:del, :deposit, {:drep, cred}, dep}]
  end

  # ---- DRep update (18) — OVERWRITE drep entry (anchor/expiry) ----
  def effects(%{type: :drep_update, credential: cred} = c, read, _pp) do
    [set_op(:drep, cred, read, drep_entry(c))]
  end

  # ---- committee hot auth (14) / resignation (15) — cc_hot map ----
  def effects(%{type: :committee_hot_auth, cold: cold, hot: hot}, read, _pp) do
    [set_op(:cc_hot, cold, read, hot)]
  end

  def effects(%{type: :committee_resignation, cold: cold}, read, _pp) do
    del_if([], read.(:cc_hot, cold), :cc_hot, cold)
  end

  # Unknown / unmodelled cert → no ops (decoded but no Tier-a effect we track).
  def effects(_cert, _read, _pp), do: []

  # ---- helpers ----

  # A registration's reward-entry + deposit ops (shared by combined certs 11/12/13).
  defp reg(c, pp) do
    dep = Map.get(c, :deposit) || pp.key_deposit
    [{:put, :reward, c.credential, 0}, {:put, :deposit, {:cred, c.credential}, dep}]
  end

  # An overwrite op capturing the current value as `old` (nil if unset — inverse restores nil).
  defp set_op(domain, key, read, new), do: {:set, domain, key, read.(domain, key), new}

  # Append a :del op to `ops` iff there IS an old value to remove (else `ops` unchanged).
  # Signature: (ops, old, domain, key) — ops first, so it chains with the |> pipe.
  defp del_if(ops, nil, _domain, _key), do: ops
  defp del_if(ops, old, domain, key), do: ops ++ [{:del, domain, key, old}]

  # What we store for a drep entry (anchor kept; expiry/activity is Tier-b epoch logic — placeholder).
  defp drep_entry(c), do: %{anchor: Map.get(c, :anchor)}
end
