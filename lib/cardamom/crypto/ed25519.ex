defmodule Cardamom.Crypto.Ed25519 do
  @moduledoc """
  Edwards25519 field + curve arithmetic, in plain BEAM bignums — the substrate for
  ECVRF VERIFICATION (`Cardamom.Crypto.VRF`). Verify-only: NOTHING here is secret, so
  constant-time discipline is deliberately NOT applied (the timing-side-channel ban on
  pure-language crypto is about signing keys; there are none on the verify path).

  Field: GF(2²⁵⁵−19). Curve: twisted Edwards −x²+y² = 1+d·x²·y², d non-square, cofactor 8.
  Points are EXTENDED homogeneous coords `{X, Y, Z, T}` with x=X/Z, y=Y/Z, T=XY/Z; the
  addition law is the complete unified formula (RFC 8032 §5.1.4), correct for doubling too
  (d non-square ⇒ no exceptional points), so a single `add/2` powers `smul/2`.

  Encoding is RFC 8032: 32 bytes little-endian y, top bit = x's low bit (sign).
  """

  import Bitwise

  @p 57_896_044_618_658_097_711_785_492_504_343_953_926_634_992_332_820_282_019_728_792_003_956_564_819_949
  @d 37_095_705_934_669_439_343_138_083_508_754_565_189_542_113_879_843_219_016_388_785_533_085_940_283_555
  # sqrt(-1) mod p
  @i 19_681_161_376_707_505_956_807_079_304_988_542_015_446_066_515_923_890_162_744_021_073_123_829_784_752
  @sqrt_exp div(@p - 5, 8)
  @leg_exp div(@p - 1, 2)
  @mask255 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF

  # Standard Ed25519 base point (for s·B in the VRF verify equation).
  @bx 15_112_221_349_535_400_772_501_151_409_588_531_511_454_012_693_041_857_206_046_113_283_949_847_762_202
  @by 46_316_835_694_926_478_169_428_394_003_475_163_141_307_993_866_256_225_615_783_033_603_165_251_855_960

  @identity {0, 1, 1, 0}

  def p, do: @p
  def base_point, do: {@bx, @by, 1, fmul(@bx, @by)}
  def identity, do: @identity

  # ---- field arithmetic (a, b assumed already reduced into [0, p)) ----

  def fadd(a, b), do: rem(a + b, @p)
  def fsub(a, b), do: rem(a - b + @p, @p)
  def fmul(a, b), do: rem(a * b, @p)
  def fneg(a), do: rem(@p - a, @p)
  def finv(a), do: fpow(a, @p - 2)

  @doc "Modular exponentiation base^exp mod p (square-and-multiply)."
  def fpow(base, exp) when exp >= 0, do: do_pow(rem(base, @p), exp, 1)
  defp do_pow(_b, 0, acc), do: acc

  defp do_pow(b, e, acc) do
    acc = if (e &&& 1) == 1, do: rem(acc * b, @p), else: acc
    do_pow(rem(b * b, @p), e >>> 1, acc)
  end

  @doc "Legendre: true iff a is a quadratic residue mod p (0 counts as square)."
  def square?(0), do: true
  def square?(a), do: fpow(a, @leg_exp) == 1

  # ---- point encoding ----

  @doc "Decode a 32-byte RFC-8032 point encoding into an extended point, or :error."
  def decompress(bytes) when is_binary(bytes) and byte_size(bytes) == 32 do
    enc = :binary.decode_unsigned(bytes, :little)
    sign = enc >>> 255 &&& 1
    y = enc &&& @mask255

    if y >= @p do
      :error
    else
      point_from_y(y, sign)
    end
  end

  def decompress(_), do: :error

  @doc """
  Recover the full point from a y-coordinate and an x sign bit (0/1), the core of
  decompression: solve x² = (y²−1)/(d·y²+1), take the sqrt, fix the sign. :error if
  no square root exists (y is not on the curve).
  """
  def point_from_y(y, sign) do
    yy = fmul(y, y)
    u = fsub(yy, 1)
    v = fadd(fmul(@d, yy), 1)

    case recover_x(u, v) do
      :error ->
        :error

      x0 ->
        x =
          cond do
            x0 == 0 and sign == 1 -> :error
            (x0 &&& 1) != sign -> fneg(x0)
            true -> x0
          end

        if x == :error, do: :error, else: {x, y, 1, fmul(x, y)}
    end
  end

  # x = sqrt(u/v) by the RFC 8032 p≡5 mod 8 method.
  defp recover_x(u, v) do
    v3 = fmul(v, fmul(v, v))
    v7 = fmul(v3, fmul(v3, v))
    x = fmul(fmul(u, v3), fpow(fmul(u, v7), @sqrt_exp))
    vxx = fmul(v, fmul(x, x))

    cond do
      vxx == u -> x
      vxx == fneg(u) -> fmul(x, @i)
      true -> :error
    end
  end

  @doc "Encode an extended point to its 32-byte RFC-8032 form."
  def compress({x, y, z, _t}) do
    zi = finv(z)
    xa = fmul(x, zi)
    ya = fmul(y, zi)
    enc = ya ||| (xa &&& 1) <<< 255
    <<enc::unsigned-little-size(256)>>
  end

  # ---- group operations ----

  @doc "Complete unified addition (RFC 8032 §5.1.4); also correct for P+P (doubling)."
  def add({x1, y1, z1, t1}, {x2, y2, z2, t2}) do
    a = fmul(fsub(y1, x1), fsub(y2, x2))
    b = fmul(fadd(y1, x1), fadd(y2, x2))
    c = fmul(fmul(t1, fmul(2, @d)), t2)
    dd = fmul(fmul(2, z1), z2)
    e = fsub(b, a)
    f = fsub(dd, c)
    g = fadd(dd, c)
    h = fadd(b, a)
    {fmul(e, f), fmul(g, h), fmul(f, g), fmul(e, h)}
  end

  @doc "Point negation: (x,y) ↦ (−x,y)."
  def negate({x, y, z, t}), do: {fneg(x), y, z, fneg(t)}

  @doc "Scalar multiplication k·P (LSB-first double-and-add; k a non-negative integer)."
  def smul(k, p) when is_integer(k) and k >= 0, do: do_smul(k, p, @identity)
  defp do_smul(0, _p, acc), do: acc

  defp do_smul(k, p, acc) do
    acc = if (k &&& 1) == 1, do: add(acc, p), else: acc
    do_smul(k >>> 1, add(p, p), acc)
  end

  @doc "Affine (x,y) of an extended point — for tests/assertions."
  def to_affine({x, y, z, _t}) do
    zi = finv(z)
    {fmul(x, zi), fmul(y, zi)}
  end

  @doc "Point equality up to projective scaling."
  def equal?(p1, p2), do: to_affine(p1) == to_affine(p2)
end
