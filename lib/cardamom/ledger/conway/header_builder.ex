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

  @era 6

  @doc """
  Build a header. Opts: `:block_number`, `:slot`, `:prev_hash` (32-byte binary or
  nil). Returns `%{raw: raw_bytes, hash: <<32>>, envelope: wire_term, slot:, block_number:}`.
  """
  def build(opts \\ []) do
    block_number = Keyword.get(opts, :block_number, 0)
    slot = Keyword.get(opts, :slot, 0)
    prev_hash = Keyword.get(opts, :prev_hash, nil)

    # Real Praos HeaderBody: a FLAT 15-element array (OCert + ProtVer inlined as
    # CBORGroups), matching ouroboros-consensus + the captured Preview fixture.
    header_body = [
      block_number,
      slot,
      prev_hash_field(prev_hash),
      b(32),
      b(32),
      [b(64), b(80)],
      [b(64), b(80)],
      Keyword.get(opts, :block_body_size, 1024),
      # block_body_hash: an explicit value (a real commitment, for block building) or
      # a random placeholder (header-only tests that don't verify the body).
      Keyword.get(opts, :block_body_hash, b(32)),
      # opcert flattened: hot_vkey, n, kes_period, sigma
      b(32),
      0,
      0,
      b(64),
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
end
