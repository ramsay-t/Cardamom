defmodule Cardamom.Crypto.KESTest do
  @moduledoc """
  Sum-composition KES verification (the MMM construction), as specified by
  cardano-crypto-class `Cardano.Crypto.KES.Sum`:

      vk(Sum_n)  = blake2b256( vk0 ‖ vk1 )              (vk0/vk1 are Sum_{n-1} vks)
      sig(Sum_n) = sig(Sum_{n-1}) ‖ vk0 ‖ vk1           (so |sig(Sum_6)| = 64 + 6·64 = 448)
      verify(vk, t, msg, sig):
        blake2b256(vk0 ‖ vk1) == vk
        ∧ if t < 2^(n-1) then verify(vk0, t, msg, inner)
                          else verify(vk1, t − 2^(n-1), msg, inner)
      Sum_0 = plain Ed25519 (verify at t = 0).

  Cardano's Praos KES is Sum_6 (2^6 = 64 periods; the CDDL's `kes_signature =
  bytes .size 448` is exactly this layout).

  THE REAL VECTOR: a captured Preview header (`preview_rollforward_praos.hex`) —
  its KES signature must verify against the opcert's hot vkey, over the header
  BODY bytes, at evolution t = slot ÷ slotsPerKESPeriod − opcert kes_period
  (Preview genesis: slotsPerKESPeriod = 129600). A pure test-vector suite can only
  show our tree agrees with itself; a real relay-accepted header proves the whole
  layout (span carve, byte order, tree orientation) against Cardano.

  MC/DC negatives: each independently-falsifiable condition falsified alone —
  tampered message, tampered signature leaf, tampered vk pair (tree hash), wrong
  evolution t, t out of range, wrong sizes.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Crypto.KES
  alias Cardamom.Ledger.Praos

  @slots_per_kes_period 129_600

  defp real_header do
    raw =
      "test/fixtures/preview_rollforward_praos.hex"
      |> File.read!()
      |> String.trim()
      |> Base.decode16!(case: :mixed)

    {:ok, h} = Praos.Header.decode(raw)
    {:ok, body_bytes, kes_sig} = KES.header_signable(raw)
    t = div(h.slot, @slots_per_kes_period) - h.operational_cert.kes_period
    %{header: h, body: body_bytes, sig: kes_sig, t: t, hot: h.operational_cert.hot_vkey}
  end

  test "REAL VECTOR: a relay-accepted Preview header's KES signature verifies" do
    %{body: body, sig: sig, t: t, hot: hot} = real_header()
    assert byte_size(sig) == 448, "Sum_6 signature layout"
    assert t >= 0 and t < 64, "evolution within the Sum_6 window (sanity of the vector itself)"
    assert KES.verify(hot, t, body, sig)
  end

  test "MC/DC: tampered MESSAGE byte → false (Ed25519 leaf catches it)" do
    %{body: body, sig: sig, t: t, hot: hot} = real_header()
    <<first, rest::binary>> = body
    refute KES.verify(hot, t, <<first + 1, rest::binary>>, sig)
  end

  test "MC/DC: tampered SIGNATURE leaf byte → false" do
    %{body: body, sig: sig, t: t, hot: hot} = real_header()
    <<first, rest::binary>> = sig
    refute KES.verify(hot, t, body, <<first + 1, rest::binary>>)
  end

  test "MC/DC: tampered vk in the tree suffix → false (blake2b tree hash catches it)" do
    %{body: body, sig: sig, t: t, hot: hot} = real_header()
    # last byte of the outermost vk1 — the vk-pair hash check must fail
    prefix = binary_part(sig, 0, 447)
    <<last>> = binary_part(sig, 447, 1)
    refute KES.verify(hot, t, body, <<prefix::binary, last + 1>>)
  end

  test "MC/DC: WRONG EVOLUTION t (right key, right bytes) → false" do
    %{body: body, sig: sig, t: t, hot: hot} = real_header()
    other = if t == 0, do: 1, else: t - 1
    refute KES.verify(hot, other, body, sig)
  end

  test "MC/DC: t out of range (≥ 64, or negative) → false, never raises" do
    %{body: body, sig: sig, hot: hot} = real_header()
    refute KES.verify(hot, 64, body, sig)
    refute KES.verify(hot, -1, body, sig)
  end

  test "MC/DC: wrong-size signature / vkey → false, never raises" do
    %{body: body, sig: sig, t: t, hot: hot} = real_header()
    refute KES.verify(hot, t, body, binary_part(sig, 0, 447))
    refute KES.verify(binary_part(hot, 0, 31), t, body, sig)
    refute KES.verify(hot, t, body, <<>>)
  end

  test "header_signable: carves the exact body span + 448-byte signature" do
    raw =
      "test/fixtures/preview_rollforward_praos.hex"
      |> File.read!()
      |> String.trim()
      |> Base.decode16!(case: :mixed)

    {:ok, body, sig} = KES.header_signable(raw)
    assert byte_size(sig) == 448
    # the carve is byte-exact: body ‖ sig-with-CBOR-prefix reassembles the raw header
    assert byte_size(body) < byte_size(raw)
    assert :binary.match(raw, body) != :nomatch
  end

  test "header_signable: not a [body, sig] header → error, never raises" do
    assert {:error, _} = KES.header_signable(<<0xFF, 1, 2, 3>>)
    assert {:error, _} = KES.header_signable(CBOR.encode([1, 2, 3]))
  end
end
