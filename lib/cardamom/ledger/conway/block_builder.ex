defmodule Cardamom.Ledger.Conway.BlockBuilder do
  @moduledoc """
  Builds structurally-real Conway blocks with a CORRECT `block_body_hash` commitment
  — the single source of correct block shape for SimPeer, LogReplayPeer, and tests
  (mirrors `HeaderBuilder` for headers).

  A block is `[header, tx_bodies, tx_witness_sets, aux_data, invalid_txs]`. We build
  the four body segments, compute the spec-exact body hash over them
  (hash-of-four-segwit-hashes, see `Cardamom.Ledger.Conway.Block`), embed THAT hash
  in the header's `block_body_hash` field, then assemble the block. So a built block
  genuinely verifies — and tampering with any segment breaks verification, which is
  what the security check must catch.

  The segments must be hashed over the SAME bytes that end up in the block, so we
  encode each segment once and reuse those exact bytes both for the hash and for the
  block assembly (`encodePreEncoded` fidelity).
  """

  alias Cardamom.Crypto
  alias Cardamom.Ledger.Conway.HeaderBuilder

  # Conway era tag (confirmed from real Preview block-fetch: `82 05 ...`).
  @era 5

  @doc """
  Build a block. Opts: `:block_number`, `:slot`, `:prev_hash`, `:tx_count` (default
  0 — an empty block; bumping it adds placeholder-but-well-formed tx bodies).
  Returns `%{raw:, hash:, header_hash:, tx_count:, envelope:}` where `envelope` is
  the block-fetch wire shape `#6.24(bytes)` (tag-24 wrapped, like a header).
  """
  def build(opts \\ []) do
    tx_count = Keyword.get(opts, :tx_count, 0)

    # The four segwit segments, encoded ONCE (these exact bytes feed both the body
    # hash and the block). M1: bodies are placeholder maps; witnesses/aux/invalid
    # empty. Shape need only be well-formed CBOR for block-LEVEL handling.
    bodies = for i <- 0..(tx_count - 1)//1, do: %{0 => i}
    bodies_bytes = CBOR.encode(bodies)
    wits_bytes = CBOR.encode(List.duplicate(%{}, tx_count))
    aux_bytes = CBOR.encode(%{})
    invalid_bytes = CBOR.encode([])

    # Spec-exact body hash: blake2b256( H(bodies) <> H(wits) <> H(aux) <> H(invalid) ).
    body_hash =
      Crypto.blake2b_256(
        Crypto.blake2b_256(bodies_bytes) <>
          Crypto.blake2b_256(wits_bytes) <>
          Crypto.blake2b_256(aux_bytes) <>
          Crypto.blake2b_256(invalid_bytes)
      )

    # Header commits to that body hash.
    hdr =
      HeaderBuilder.build(
        block_number: Keyword.get(opts, :block_number, 0),
        slot: Keyword.get(opts, :slot, 0),
        prev_hash: Keyword.get(opts, :prev_hash),
        block_body_hash: body_hash
      )

    # The INNER block: the 5-element array [header, bodies, wits, aux, invalid],
    # spliced from the SAME pre-encoded segment bytes (so Block.verify_body recomputes
    # an identical body hash) — byte fidelity, not re-encoded decoded terms.
    inner =
      <<0x85>> <>
        hdr.raw <> bodies_bytes <> wits_bytes <> aux_bytes <> invalid_bytes

    # The real wire shape is ERA-WRAPPED: [era, inner_block] (CONFIRMED from real
    # Preview: `82 05 85 ...` = [era 5 (Conway), array(5)]). Build that, not the bare
    # inner block — so round-trip tests exercise the SAME structure real blocks have.
    era_prefix = <<0x82>> <> CBOR.encode(@era)
    raw = era_prefix <> inner

    %{
      raw: raw,
      hash: Crypto.blake2b_256(raw),
      header_hash: hdr.hash,
      slot: hdr.slot,
      block_number: hdr.block_number,
      tx_count: tx_count,
      # Byte offset where the bodies segment begins: era_prefix + inner's 0x85 array
      # byte + the header. Lets tests tamper body content precisely while keeping
      # structure valid (exercises verify_body, not a CBOR break).
      bodies_offset: byte_size(era_prefix) + 1 + byte_size(hdr.raw),
      envelope: %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: raw}}
    }
  end
end
