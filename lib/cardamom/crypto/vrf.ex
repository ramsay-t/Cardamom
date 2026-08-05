defmodule Cardamom.Crypto.VRF do
  @moduledoc """
  ECVRF verification — Cardano's Praos VRF: `ECVRF-ED25519-SHA512-Elligator2`,
  IETF CFRG VRF **draft-03** (suite octet 0x04). 80-byte proofs (Γ‖c‖s = 32‖16‖32),
  64-byte outputs — the shapes on every real Praos header (draft-13's 128-byte
  batch-compat variant exists in the Haskell code but is NOT what the wire carries).

  VERIFY-ONLY: verification touches no secret material (vk, proof, input, output are
  all public), which is exactly why the pure-Elixir implementation on
  `Cardamom.Crypto.Ed25519` is defensible — the timing-side-channel ban is about
  signing keys, of which there are none here. Proving (the forging milestone) gets a
  native binding when its time comes.

  The algorithm (draft-03 §5.3, reconciled with the IOG libsodium fork the Haskell
  node binds to):

    * decode_proof(π): Γ = decompress(π[0..31]); c = LE-int(π[32..47]);
      s = LE-int(π[48..79]).
    * hash_to_curve(Y, α) [Elligator2]: r = SHA512(0x04‖0x01‖Y‖α)[0..31], top bit
      cleared; H = 8·elligator2(r) — Montgomery `u = −A/(1+2r²)` (or `−u−A` if the
      curve point is a non-square), converted to an Edwards point, then the cofactor
      (×8) clears it into the prime-order subgroup. (The ×8 is the one Elligator2
      detail the draft text underspecifies; confirmed empirically against the vectors.)
    * verify(Y, π, α): H = hash_to_curve; U = s·B − c·Y; V = s·H − c·Γ;
      c′ = SHA512(0x04‖0x02‖H‖Γ‖U‖V)[0..15]; accept iff c′ == c.
    * proof_to_output(π): β = SHA512(0x04‖0x03‖compress(8·Γ)) — the cofactor (8)
      clears Γ into the prime-order subgroup. Needs NO input α, so it validates
      against real headers before epoch-nonce evolution exists.

  Pinned by IOG's official draft-03 vectors AND 300 real network-accepted proofs
  (test/cardamom/crypto/vrf_test.exs, test/fixtures/vrf/).

  LEADER-ELECTION ORACLE (the not-yet-built payoff): with `Cardamom.Ledger.Nonce`
  giving η per epoch, `verify(vrf_vkey, proof, blake2b(slot ‖ η))` over every stored
  header validates our whole leadership stack against the chain. It needs a from-genesis
  (or published-anchor) nonce fold over CONTIGUOUS headers, so it lands with the replay
  driver — VRF suite tier 3, deliberately still absent.
  """

  import Bitwise
  alias Cardamom.Crypto.Ed25519, as: E

  @suite 0x04
  @mont_a 486_662
  @mask255 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF

  @doc """
  Verify an ECVRF draft-03 proof: `vk` (32 bytes), `proof` (80 bytes), over `alpha`.
  Returns `{:ok, beta}` (the 64-byte output) on success, `:error` otherwise. Never raises.
  """
  @spec verify(binary(), binary(), binary()) :: {:ok, <<_::512>>} | :error
  def verify(vk, proof, alpha)
      when is_binary(vk) and byte_size(vk) == 32 and is_binary(proof) and
             byte_size(proof) == 80 and is_binary(alpha) do
    with {gamma, c, s} when gamma != :error <- decode_proof(proof),
         y when y != :error <- E.decompress(vk),
         h when h != :error <- hash_to_curve(vk, alpha) do
      # U = s·B − c·Y ; V = s·H − c·Γ
      u = E.add(E.smul(s, E.base_point()), E.negate(E.smul(c, y)))
      v = E.add(E.smul(s, h), E.negate(E.smul(c, gamma)))

      c_prime =
        sha512([@suite, 0x02, E.compress(h), E.compress(gamma), E.compress(u), E.compress(v)])
        |> binary_part(0, 16)

      if c_prime == binary_part(proof, 32, 16), do: {:ok, output(gamma)}, else: :error
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def verify(_vk, _proof, _alpha), do: :error

  @doc """
  Derive the VRF output β from a proof alone — `SHA512(0x04 ‖ 0x03 ‖ compress(8·Γ))`.
  Needs no input α (stage-A validation against real headers). `{:ok, beta}` | `:error`.
  """
  @spec proof_to_output(binary()) :: {:ok, <<_::512>>} | :error
  def proof_to_output(proof) when is_binary(proof) and byte_size(proof) == 80 do
    case decode_proof(proof) do
      {gamma, _c, _s} when gamma != :error -> {:ok, output(gamma)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def proof_to_output(_), do: :error

  # β = SHA512(suite ‖ 0x03 ‖ compress(cofactor·Γ)), cofactor = 8.
  defp output(gamma), do: sha512([@suite, 0x03, E.compress(E.smul(8, gamma))])

  # π = Γ(32) ‖ c(16) ‖ s(32); c, s little-endian integers (RFC-8032 scalar convention).
  defp decode_proof(<<gamma_b::binary-size(32), c_b::binary-size(16), s_b::binary-size(32)>>) do
    {E.decompress(gamma_b), :binary.decode_unsigned(c_b, :little),
     :binary.decode_unsigned(s_b, :little)}
  end

  # ---- Elligator2 hash-to-curve (draft-03 ECVRF-ED25519-SHA512-Elligator2) ----

  @doc false
  # H = elligator2( SHA512(suite ‖ 0x01 ‖ Y ‖ α)[0..31] with top bit cleared ).
  def hash_to_curve(vk, alpha) do
    <<r::binary-size(32), _::binary>> = sha512([@suite, 0x01, vk, alpha])
    r_int = :binary.decode_unsigned(r, :little) &&& @mask255
    # draft-03 clears the cofactor (×8) so H lands in the prime-order subgroup.
    E.smul(8, elligator2(rem(r_int, E.p())))
  end

  # Map a field element r to an Edwards point (libsodium ge25519_from_uniform, sign bit 0).
  defp elligator2(r) do
    # Montgomery u-candidate: −A / (1 + 2r²)
    denom = E.fadd(E.fmul(2, E.fmul(r, r)), 1)
    u0 = E.fneg(E.fmul(@mont_a, E.finv(denom)))

    # gx = u0³ + A·u0² + u0 ; if non-square, use u = −u0 − A instead
    u0sq = E.fmul(u0, u0)
    gx = E.fadd(E.fadd(E.fmul(u0, u0sq), E.fmul(@mont_a, u0sq)), u0)
    u = if E.square?(gx), do: u0, else: E.fsub(E.fneg(u0), @mont_a)

    # Montgomery u → Edwards y = (u−1)/(u+1); Edwards x sign = 0 (top bit was cleared).
    y = E.fmul(E.fsub(u, 1), E.finv(E.fadd(u, 1)))
    E.point_from_y(y, 0)
  end

  defp sha512(iodata), do: :crypto.hash(:sha512, iodata)
end
