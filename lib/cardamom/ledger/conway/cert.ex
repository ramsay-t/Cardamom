defmodule Cardamom.Ledger.Conway.Cert do
  @moduledoc """
  Decode Conway CERTIFICATES (tx body key 4) — the crypto-free structural half of ledger-state
  ingestion. A certificate is a CBOR array `[tag, ...fields]` STATING a ledger action (register a
  stake credential, delegate, register a pool/DRep, …). The crypto that *authorises* it lives in
  the witness set, NOT here — as an observer we decode what the cert SAYS and (elsewhere) apply its
  state effect; we don't re-verify signatures.

  Authoritative shapes: cardano-ledger conway.cddl (cert union lines 30-48, defs 434-539) +
  formal-ledger Certs.lagda.md. Each clause returns a tagged map; unknown/undecodable → {:unknown,...}
  so a new cert type can't crash ingestion. Sub-types:
    credential = [0, keyhash28] | [1, scripthash28]     → {:key, h} | {:script, h}
    drep       = [0,h] | [1,h] | [2] | [3]              → {:key,h}|{:script,h}|:abstain|:no_confidence
    anchor     = [url, hash32] | nil
    pool_params (tag 3) = the full operator/vrf/pledge/cost/margin/reward_acct/owners/relays/metadata tuple
  """

  @doc "Decode the raw certs list (Conway.Tx `:certs`) into tagged maps. nil/empty → []."
  @spec decode_all(list() | nil) :: [map()]
  def decode_all(nil), do: []
  def decode_all(certs) when is_list(certs), do: Enum.map(certs, &decode/1)
  def decode_all(_), do: []

  @doc "Decode one certificate array to a tagged map. Never raises."
  @spec decode(list()) :: map()
  def decode(cert)

  # --- stake credential registration / deregistration (deprecated no-deposit forms) ---
  def decode([0, cred]), do: %{type: :stake_registration, credential: credential(cred)}
  def decode([1, cred]), do: %{type: :stake_deregistration, credential: credential(cred)}

  # --- delegation to a stake pool ---
  def decode([2, cred, pool]),
    do: %{type: :stake_delegation, credential: credential(cred), pool: bytes(pool)}

  # --- pool registration / retirement ---
  def decode([3 | pool_params]), do: %{type: :pool_registration, params: pool_params(pool_params)}
  def decode([4, pool, epoch]), do: %{type: :pool_retirement, pool: bytes(pool), epoch: epoch}

  # --- Conway stake reg/unreg WITH explicit deposit (tags 7/8) ---
  def decode([7, cred, coin]),
    do: %{type: :stake_registration, credential: credential(cred), deposit: coin}

  def decode([8, cred, coin]),
    do: %{type: :stake_deregistration, credential: credential(cred), refund: coin}

  # --- vote delegation to a DRep ---
  def decode([9, cred, drep]),
    do: %{type: :vote_delegation, credential: credential(cred), drep: drep(drep)}

  # --- combined register/delegate certs (10-13) ---
  def decode([10, cred, pool, drep]),
    do: %{type: :stake_and_vote_delegation, credential: credential(cred), pool: bytes(pool), drep: drep(drep)}

  def decode([11, cred, pool, coin]),
    do: %{type: :stake_registration_and_delegation, credential: credential(cred), pool: bytes(pool), deposit: coin}

  def decode([12, cred, drep, coin]),
    do: %{type: :vote_registration_and_delegation, credential: credential(cred), drep: drep(drep), deposit: coin}

  def decode([13, cred, pool, drep, coin]),
    do: %{
      type: :stake_vote_registration_and_delegation,
      credential: credential(cred),
      pool: bytes(pool),
      drep: drep(drep),
      deposit: coin
    }

  # --- constitutional committee ---
  def decode([14, cold, hot]),
    do: %{type: :committee_hot_auth, cold: credential(cold), hot: credential(hot)}

  def decode([15, cold, anchor]),
    do: %{type: :committee_resignation, cold: credential(cold), anchor: anchor(anchor)}

  # --- DRep registration / deregistration / update ---
  def decode([16, cred, coin, anchor]),
    do: %{type: :drep_registration, credential: credential(cred), deposit: coin, anchor: anchor(anchor)}

  def decode([17, cred, coin]),
    do: %{type: :drep_deregistration, credential: credential(cred), refund: coin}

  def decode([18, cred, anchor]),
    do: %{type: :drep_update, credential: credential(cred), anchor: anchor(anchor)}

  # Unknown / future cert shape — keep the tag, don't crash ingestion.
  def decode([tag | rest]), do: %{type: :unknown, tag: tag, raw: rest}
  def decode(other), do: %{type: :unknown, raw: other}

  # ---- sub-type decoders ----

  # credential = [0, addr_keyhash] | [1, script_hash]  → {:key, h} | {:script, h}
  defp credential([0, h]), do: {:key, bytes(h)}
  defp credential([1, h]), do: {:script, bytes(h)}
  defp credential(other), do: {:unknown, other}

  # drep = [0,h]|[1,h]|[2]|[3]
  defp drep([0, h]), do: {:key, bytes(h)}
  defp drep([1, h]), do: {:script, bytes(h)}
  defp drep([2]), do: :abstain
  defp drep([3]), do: :no_confidence
  defp drep(other), do: {:unknown, other}

  defp anchor(nil), do: nil
  defp anchor([url, hash]), do: %{url: url, data_hash: bytes(hash)}
  defp anchor(_), do: nil

  # pool_params = (operator, vrf_keyhash, pledge, cost, margin([n,d]), reward_account, owners,
  #               relays, metadata/nil). Kept structurally; relays/metadata retained raw (we don't
  #               act on them, but keep for completeness/forensics).
  defp pool_params([operator, vrf, pledge, cost, margin, reward_account, owners, relays, metadata]) do
    %{
      operator: bytes(operator),
      vrf_keyhash: bytes(vrf),
      pledge: pledge,
      cost: cost,
      margin: margin(margin),
      reward_account: bytes(reward_account),
      owners: owners |> unset() |> Enum.map(&bytes/1),
      relays: relays,
      metadata: metadata
    }
  end

  defp pool_params(other), do: %{malformed: other}

  defp margin([n, d]), do: {n, d}
  defp margin(%CBOR.Tag{tag: 30, value: [n, d]}), do: {n, d}
  defp margin(other), do: other

  # A CBOR set (#6.258([...])) or a bare list → the underlying list.
  defp unset(%CBOR.Tag{tag: 258, value: l}) when is_list(l), do: l
  defp unset(l) when is_list(l), do: l
  defp unset(_), do: []

  defp bytes(%CBOR.Tag{tag: :bytes, value: b}), do: b
  defp bytes(b) when is_binary(b), do: b
  defp bytes(other), do: other
end
