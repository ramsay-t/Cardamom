defmodule Cardamom.Crypto.KES do
  @moduledoc """
  KES (Key-Evolving Signature) VERIFICATION — the sum composition (MMM construction)
  Cardano uses to sign block headers, `Sum_6` over Ed25519 with blake2b-256.

  SOURCE OF TRUTH: cardano-crypto-class `Cardano.Crypto.KES.Sum` (there is no prose or
  CDDL spec of the algorithm — a byte-exact code-only construction, same class as the
  block-body hash; flagged in docs/network-specs.md §3). The construction:

      vk(Sum_n)  = blake2b256( vk0 ‖ vk1 )            vk0/vk1: the two Sum_{n-1} subtree vks
      sig(Sum_n) = sig(Sum_{n-1}) ‖ vk0 ‖ vk1         inner signature FIRST, then the vk pair
      Sum_0     = plain Ed25519 (SingleKES)

  so a `Sum_6` signature is 64 + 6·64 = 448 bytes — exactly the ledger CDDL's
  `kes_signature = bytes .size 448`. Verification walks the tree: check the vk pair
  hashes to the expected vk, then recurse into the half selected by the evolution `t`
  (left if `t < 2^(n-1)`, else right with `t − 2^(n-1)`), down to an Ed25519 verify at
  the leaf. Each period `t` therefore has its own leaf key; signing with the wrong
  evolution fails verification.

  Verification is the validator surface. `generate/1` + `sign/3` also exist — NOT for
  live use (an observer holds no signing keys) but because the simulated peer and tests
  must produce headers INDISTINGUISHABLE from real ones (the sim is never more lenient
  than reality), which requires genuinely KES-signed headers. Throwaway keys only.
  (They also happen to be the seed of the far-future forging milestone.)

  What the header actually signs: the CBOR bytes of the HEADER BODY — the first element
  of the `[header_body, kes_signature]` pair — byte-exact as received (the
  SignableRepresentation is the encoding itself). `header_signable/1` carves both out
  of a raw header without re-encoding anything.

  Pinned by a REAL relay-accepted Preview header in test/cardamom/crypto/kes_test.exs —
  the only vector that proves layout + orientation against Cardano itself, per the
  verify-against-reality discipline.
  """

  alias Cardamom.Crypto

  @levels 6
  @periods 64
  @sig_size 448

  @doc """
  Verify a `Sum_#{@levels}` KES signature: `vk` (32 bytes, the tree root), evolution
  `t` (`0..#{@periods - 1}`), over `msg`, with `sig` (#{@sig_size} bytes). Strictly
  boolean — malformed input is `false`, never a raise (a lying header is rejected,
  not a crash).
  """
  @spec verify(binary(), integer(), binary(), binary()) :: boolean()
  def verify(vk, t, msg, sig)
      when is_binary(vk) and byte_size(vk) == 32 and is_integer(t) and
             t >= 0 and t < @periods and is_binary(msg) and is_binary(sig) and
             byte_size(sig) == @sig_size do
    verify_sum(@levels, vk, t, msg, sig)
  end

  def verify(_vk, _t, _msg, _sig), do: false

  # Sum_0 = SingleKES = plain Ed25519. t is already reduced to 0 by the descent.
  defp verify_sum(0, vk, 0, msg, sig), do: Crypto.ed25519_verify(msg, sig, vk)
  defp verify_sum(0, _vk, _t, _msg, _sig), do: false

  # Sum_n: sig = inner ‖ vk0 ‖ vk1. The vk pair must hash to the expected vk
  # (the tree commitment), then descend into the half `t` selects.
  defp verify_sum(n, vk, t, msg, sig) do
    inner_size = byte_size(sig) - 64
    <<inner::binary-size(^inner_size), vk0::binary-size(32), vk1::binary-size(32)>> = sig
    half = Bitwise.bsl(1, n - 1)

    Crypto.blake2b_256(<<vk0::binary, vk1::binary>>) == vk and
      if t < half,
        do: verify_sum(n - 1, vk0, t, msg, inner),
        else: verify_sum(n - 1, vk1, t - half, msg, inner)
  end

  @doc """
  Generate a full `Sum_n` key tree (default `Sum_#{@levels}`): every leaf is a real
  Ed25519 keypair, every node commits to its children via blake2b-256. Honest-but-eager
  construction (a real signer evolves keys and erases old ones; for verification-testing
  the whole tree at once is fine). 2^#{@levels} = #{@periods} leaf keypairs.
  """
  @spec generate(non_neg_integer()) :: tuple()
  def generate(levels \\ @levels)

  def generate(0) do
    {vk, sk} = :crypto.generate_key(:eddsa, :ed25519)
    {:leaf, vk, sk}
  end

  def generate(n) when is_integer(n) and n > 0 do
    left = generate(n - 1)
    right = generate(n - 1)
    {:node, n, Crypto.blake2b_256(<<vk(left)::binary, vk(right)::binary>>), left, right}
  end

  @doc "The verification key (tree root for `Sum_n`, the raw Ed25519 vk for a leaf)."
  @spec vk(tuple()) :: binary()
  def vk({:leaf, vk, _sk}), do: vk
  def vk({:node, _n, vk, _l, _r}), do: vk

  @doc """
  Sign `msg` at evolution `t` with the key tree: descend to leaf `t`, Ed25519-sign,
  and append each level's vk pair on the way out — producing exactly the layout
  `verify/4` checks (#{@sig_size} bytes for `Sum_#{@levels}`).
  """
  @spec sign(tuple(), non_neg_integer(), binary()) :: binary()
  def sign({:leaf, _vk, sk}, 0, msg), do: :crypto.sign(:eddsa, :none, msg, [sk, :ed25519])

  def sign({:node, n, _vk, left, right}, t, msg) when t in 0..63 do
    half = Bitwise.bsl(1, n - 1)

    inner =
      if t < half,
        do: sign(left, t, msg),
        else: sign(right, t - half, msg)

    <<inner::binary, vk(left)::binary, vk(right)::binary>>
  end

  @doc """
  Carve the KES-signable message and the KES signature out of RAW header bytes.
  A Shelley-family header is the CBOR pair `[header_body, kes_signature]`; the signed
  message is the header body's OWN byte span (never a re-encoding — byte fidelity is
  what makes the signature check meaningful). Returns `{:ok, body_bytes, sig}` or
  `{:error, reason}`; never raises. Works for both header shapes (15-field TPraos and
  10-field Praos) — the pair layout is identical.
  """
  @spec header_signable(binary()) :: {:ok, binary(), binary()} | {:error, term()}
  def header_signable(<<0x82, rest::binary>> = _raw) do
    with {:ok, _body_term, after_body} <- CBOR.decode(rest),
         body_size = byte_size(rest) - byte_size(after_body),
         body_bytes = binary_part(rest, 0, body_size),
         {:ok, %CBOR.Tag{tag: :bytes, value: sig}, <<>>} <- CBOR.decode(after_body),
         true <- byte_size(sig) == @sig_size || {:error, {:bad_kes_sig_size, byte_size(sig)}} do
      {:ok, body_bytes, sig}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_a_header_pair}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  def header_signable(_), do: {:error, :not_a_header_pair}
end
