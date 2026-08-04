defmodule Cardamom.Ledger.Praos.Validation do
  @moduledoc """
  Praos HEADER validation — the checks that prove a header was produced by a real, staked block
  producer rather than fabricated. Spec-driven against the Ouroboros Praos formal spec
  (~/GoogleDrive/IOHK/ouroboros-consensus/docs/agda-spec/src/Spec/*) and the authoritative
  serialisations in cardano-ledger (cardano-protocol-tpraos).

  Tiers (see the header-validation plan):
    * Tier 1 — chain continuity (prev_hash, slot/blockno) — needs the parent header. TODO.
    * Tier 2a — OPERATIONAL CERTIFICATE cold-key signature (`verify_ocert/1`) — DONE here. Pure
      crypto, header-only: proves the pool's offline COLD key authorised this hot KES key.
    * Tier 2b — KES signature over the header body (`verify_kes/2`) — DONE here, via
      `Cardamom.Crypto.KES` (Sum₆; validated against 500 real stored headers spanning
      evolutions t=0..60 before gating). Proves the header was signed by the hot key the
      opcert authorised, at the correct evolution for its slot.
    * Tier 3 — VRF leadership (needs stake distribution + epoch nonce). Deferred (needs a
      native ECVRF binding — see the VRF decision note in CLAUDE_NOTES).

  Counter MONOTONICITY (opcert n ≥ last-seen for this issuer) and KES-period BOUNDS need external
  state (a per-issuer counter map / protocol params) and are NOT done here — this module is the
  self-contained CRYPTO checks. Each check returns :ok | {:invalid, reason} and never raises.
  """

  alias Cardamom.Crypto

  @doc """
  OPERATIONAL CERTIFICATE cold-key signature (Praos spec OCERT rule, check #11:
  `isSignedˢ issuerVk (encode (vkₕ, n, c₀)) τ` — OperationalCertificate.lagda:114).

  The pool's COLD key (`header.issuer_vkey`, offline, stake-registered) signs, ONCE, the triple
  that authorises a hot KES key: (hot_vkey, counter n, kes_period c₀). We recompute the exact
  signed bytes and Ed25519-verify `sigma` against the cold key. This is what ties a block to a
  real registered pool identity — an attacker without the cold secret can't forge it.

  SIGNED BYTES (byte-exact, cardano-ledger OCert.hs getSignableRepresentation, lines 149-158) —
  a RAW CONCATENATION, NOT CBOR:
      kes_vkey (32 bytes) || counter (Word64 big-endian, 8) || kes_period (Word64 big-endian, 8)
  = 48 bytes. `sigma` is the 64-byte Ed25519 signature; the cold key is 32 bytes.
  """
  @spec verify_ocert(map()) :: :ok | {:invalid, term()}
  def verify_ocert(%{issuer_vkey: cold_vkey, operational_cert: oc}) when is_map(oc) do
    with {:ok, hot} <- fetch_bin(oc, :hot_vkey),
         {:ok, sigma} <- fetch_bin(oc, :sigma),
         n when is_integer(n) <- Map.get(oc, :sequence_number),
         c0 when is_integer(c0) <- Map.get(oc, :kes_period) do
      signed = <<hot::binary, n::unsigned-big-64, c0::unsigned-big-64>>

      if Crypto.ed25519_verify(signed, sigma, cold_vkey),
        do: :ok,
        else: {:invalid, :ocert_bad_cold_signature}
    else
      _ -> {:invalid, :ocert_malformed}
    end
  end

  def verify_ocert(_), do: {:invalid, :ocert_missing}

  # KES-window parameters — genesis facts, app-env-overridable for tests/other networks.
  # Preview shelley-genesis: slotsPerKESPeriod=129600, maxKESEvolutions=62.
  defp slots_per_kes_period, do: Application.get_env(:cardamom, :slots_per_kes_period, 129_600)
  defp max_kes_evolutions, do: Application.get_env(:cardamom, :max_kes_evolutions, 62)

  @doc """
  KES signature over the header body (Praos spec OCERT rule's KES half: the header body is
  signed by the opcert's hot key at evolution `t = slot ÷ slotsPerKESPeriod − c₀`, and the
  OCERT window requires `c₀ ≤ kesPeriod(slot) < c₀ + MaxKESEvolutions`).

  Takes the header struct AND its RAW bytes: the signed message is the header body's own
  byte span (carved, never re-encoded — `Cardamom.Crypto.KES.header_signable/1`).
  Returns :ok | {:invalid, reason}; never raises.
  """
  @spec verify_kes(map(), binary()) :: :ok | {:invalid, term()}
  def verify_kes(%{operational_cert: oc, slot: slot}, raw)
      when is_map(oc) and is_integer(slot) and is_binary(raw) do
    with {:ok, hot} <- fetch_bin(oc, :hot_vkey),
         c0 when is_integer(c0) <- Map.get(oc, :kes_period),
         {:ok, body_bytes, sig} <- Cardamom.Crypto.KES.header_signable(raw) do
      t = div(slot, slots_per_kes_period()) - c0

      cond do
        t < 0 or t >= max_kes_evolutions() ->
          {:invalid, {:kes_period_out_of_range, t}}

        Cardamom.Crypto.KES.verify(hot, t, body_bytes, sig) ->
          :ok

        true ->
          {:invalid, :kes_bad_signature}
      end
    else
      {:error, reason} -> {:invalid, {:kes_unparseable, reason}}
      _ -> {:invalid, :ocert_malformed}
    end
  end

  def verify_kes(_, _), do: {:invalid, :ocert_missing}

  defp fetch_bin(map, key) do
    case Map.get(map, key) do
      b when is_binary(b) -> {:ok, b}
      _ -> :error
    end
  end
end
