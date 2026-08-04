defmodule Cardamom.Crypto.Ed25519Test do
  @moduledoc "Curve substrate sanity: known base point, group law, encode round-trip, scalar identities."
  use ExUnit.Case, async: true

  alias Cardamom.Crypto.Ed25519, as: E

  @bx 15_112_221_349_535_400_772_501_151_409_588_531_511_454_012_693_041_857_206_046_113_283_949_847_762_202
  @by 46_316_835_694_926_478_169_428_394_003_475_163_141_307_993_866_256_225_615_783_033_603_165_251_855_960
  # RFC 8032 base-point encoding (little-endian y, sign 0)
  @base_bytes Base.decode16!("5866666666666666666666666666666666666666666666666666666666666666", case: :lower)
  # Group order L
  @l 7_237_005_577_332_262_213_973_186_563_042_994_240_857_116_359_379_907_606_001_950_938_285_454_250_989

  test "field inverse and sqrt-of-minus-one behave" do
    assert E.fmul(7, E.finv(7)) == 1
    assert E.fmul(E.fpow(2, div(E.p() - 1, 4)), E.fpow(2, div(E.p() - 1, 4))) == E.fsub(0, 1)
  end

  test "the standard base-point encoding decompresses to the known coordinates" do
    assert {@bx, @by} == E.to_affine(E.decompress(@base_bytes))
    assert E.equal?(E.decompress(@base_bytes), E.base_point())
  end

  test "compress ∘ decompress is identity on the base point" do
    assert E.compress(E.base_point()) == @base_bytes
  end

  test "a bad y (≥ p, or not on curve) decompresses to :error, never raises" do
    assert E.decompress(<<0xFF::8, 0xFF::248>>) == :error
    assert E.decompress(<<1, 2, 3>>) == :error
  end

  test "group law: 2·B = B+B, and (L)·B = identity (base point has order L)" do
    two_b = E.smul(2, E.base_point())
    assert E.equal?(two_b, E.add(E.base_point(), E.base_point()))
    assert E.equal?(E.smul(@l, E.base_point()), E.identity())
  end

  test "negation and scalar linearity" do
    b = E.base_point()
    p5 = E.smul(5, b)
    assert E.equal?(E.add(p5, E.negate(p5)), E.identity())
    # 3·B + 5·B == 8·B
    assert E.equal?(E.add(E.smul(3, b), E.smul(5, b)), E.smul(8, b))
  end
end
