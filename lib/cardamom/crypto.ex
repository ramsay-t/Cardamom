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
end
