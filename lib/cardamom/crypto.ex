defmodule Cardamom.Crypto do
  @moduledoc """
  Cryptographic primitives, in one place. Correct-or-nothing: every primitive
  here is the genuine algorithm Cardano uses, pinned by a known test vector in
  the test suite — never a truncation or look-alike. A wrong hash that looks
  right is worse than useless in a cryptocurrency node.
  """

  @doc """
  BLAKE2b-256 — Cardano's hash for block/header hashes, tx ids, address hashes.

  NOT a truncation of blake2b-512: the 256-bit digest length is part of the
  algorithm's parameter block (initial state), so it must be computed natively at
  output size 32. (Erlang `:crypto`'s `:blake2b` is the 512-bit variant only,
  which is why we use the `blake2` package.) Verified against the standard vector
  blake2b-256("abc") in test/cardamom/crypto_test.exs.
  """
  @spec blake2b_256(iodata()) :: <<_::256>>
  def blake2b_256(data), do: Blake2.hash2b(data, 32)

  @doc """
  Ed25519 signature verification — Cardano's DSIGN. Returns true iff `sig` (64 bytes) is a valid
  Ed25519 signature over `msg` by the public key `vkey` (32 bytes). Cardano signs the RAW message
  bytes (no pre-hash) — Ed25519 hashes internally (SHA-512) — so we pass the message straight to
  :crypto with no digest step. Any malformed key/sig → false (never raises), so a lying header is
  rejected, not a crash.
  """
  @spec ed25519_verify(binary(), binary(), binary()) :: boolean()
  def ed25519_verify(msg, sig, vkey)
      when is_binary(msg) and byte_size(sig) == 64 and byte_size(vkey) == 32 do
    :crypto.verify(:eddsa, :none, msg, sig, [vkey, :ed25519])
  rescue
    _ -> false
  end

  def ed25519_verify(_msg, _sig, _vkey), do: false
end
