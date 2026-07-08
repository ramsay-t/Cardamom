defmodule Cardamom.Ledger.Conway.HeaderBuilder do
  @moduledoc """
  Builds structurally-real Conway headers — for SimPeer (so the fake relay's
  headers match the real wire shape) and tests. Produces:

    * the raw header bytes (CBOR-encoded `[header_body, kes_signature]`), whose
      blake2b-256 IS a real Cardano-style header hash, and
    * the chain-sync wire envelope: `[era, %CBOR.Tag{:bytes, raw}]` (the
      wrapCBORinCBOR form a real relay sends).

  Lets us chain headers correctly: a built header can carry the *previous*
  header's real hash as `prev_hash`, so SimPeer can emit a genuinely linked chain
  (real parent-hash relationships), not random noise.
  """

  alias Cardamom.Crypto

  # This builder produces the FLAT 15-field TPraos header body (two VRFs, OCert+ProtVer
  # inlined), so it must be tagged era 4 (Alonzo, the last TPraos era) — NOT era 6 (Conway),
  # which is Praos and uses the nested 10-field body. Tagging it 6 made the era-dispatching
  # decoder route SimPeer headers to the Praos decoder, which correctly rejected them. (A Praos
  # 10-field builder mode can be added later for SimPeer tests that want to exercise Praos.)
  @era 4

  @doc """
  Build a header. Opts: `:block_number`, `:slot`, `:prev_hash` (32-byte binary or
  nil). Returns `%{raw: raw_bytes, hash: <<32>>, envelope: wire_term, slot:, block_number:}`.
  """
  def build(opts \\ []) do
    block_number = Keyword.get(opts, :block_number, 0)
    slot = Keyword.get(opts, :slot, 0)
    prev_hash = Keyword.get(opts, :prev_hash, nil)

    # REAL operational-cert signature so a built header PASSES the production validation gate
    # (Praos.Validation.verify_ocert). Generate an Ed25519 COLD keypair; the cold vkey goes at the
    # issuer position, and sigma is the cold key's genuine Ed25519 signature over the opcert signed
    # bytes: hot_vkey || counter(be64) || kes_period(be64) (byte-exact, cardano-ledger OCert.hs).
    # This makes synthetic headers indistinguishable from real ones to the validator — SimPeer and
    # tests exercise the real crypto path, not a bypass. Deterministic key optional via :cold_seed.
    {cold_pub, cold_priv} = cold_keypair(opts)
    hot_vkey = :crypto.strong_rand_bytes(32)
    counter = Keyword.get(opts, :ocert_counter, 0)
    kes_period = Keyword.get(opts, :ocert_kes_period, 0)
    signed = <<hot_vkey::binary, counter::unsigned-big-64, kes_period::unsigned-big-64>>
    sigma = :crypto.sign(:eddsa, :none, signed, [cold_priv, :ed25519])

    # FLAT 15-element TPraos header body (two VRFs; OCert + ProtVer inlined as CBORGroups),
    # matching the captured era-4 Preview fixture. (This is the TPraos shape, not Praos —
    # hence @era 4 above.)
    header_body = [
      block_number,
      slot,
      prev_hash_field(prev_hash),
      %CBOR.Tag{tag: :bytes, value: cold_pub},
      b(32),
      [b(64), b(80)],
      [b(64), b(80)],
      Keyword.get(opts, :block_body_size, 1024),
      # block_body_hash: an explicit value (a real commitment, for block building) or
      # a random placeholder (header-only tests that don't verify the body).
      Keyword.get(opts, :block_body_hash, b(32)),
      # opcert flattened: hot_vkey, n, kes_period, sigma (sigma now a REAL cold-key signature)
      %CBOR.Tag{tag: :bytes, value: hot_vkey},
      counter,
      kes_period,
      %CBOR.Tag{tag: :bytes, value: sigma},
      # protver flattened: major, minor
      10,
      0
    ]

    raw = CBOR.encode([header_body, b(448)])
    hash = Crypto.blake2b_256(raw)

    %{
      raw: raw,
      hash: hash,
      slot: slot,
      block_number: block_number,
      # Real Preview wire shape (confirmed 2026-06-20): [era, #6.24(bytes)] — an
      # era tag then a CBOR tag-24 (wrapCBORinCBOR) around the header bytes.
      envelope: [@era, %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: raw}}]
    }
  end

  defp prev_hash_field(nil), do: nil
  defp prev_hash_field(h) when is_binary(h), do: %CBOR.Tag{tag: :bytes, value: h}

  defp b(n), do: %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(n)}

  # An Ed25519 cold keypair for the opcert. Random by default; pass :cold_seed (32 bytes) for a
  # DETERMINISTIC key (tests that want a stable issuer across builds). Returns {pub, priv}.
  defp cold_keypair(opts) do
    case Keyword.get(opts, :cold_seed) do
      seed when is_binary(seed) and byte_size(seed) == 32 ->
        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519, seed)
        {pub, priv}

      _ ->
        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
        {pub, priv}
    end
  end
end
