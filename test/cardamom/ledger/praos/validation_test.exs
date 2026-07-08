defmodule Cardamom.Ledger.Praos.ValidationTest do
  @moduledoc """
  Praos header validation — the OPERATIONAL CERTIFICATE cold-key signature check
  (Praos spec OCERT rule #11: isSignedˢ issuerVk (encode (vkₕ, n, c₀)) τ).

  Non-foolable: we validate against a REAL Preview block's header (block 52578), whose opcert was
  signed by a real, staked pool's cold key — so :ok proves our Ed25519 verify + the byte-exact
  signed-bytes construction (kes_vkey || counter_be64 || kes_period_be64, raw concat NOT CBOR, per
  cardano-ledger OCert.hs getSignableRepresentation) are correct. The REJECTION tests then tamper
  each signed field / the signature / the cold key and assert the check catches it — that's the
  security-critical half (a peer must not be able to forge a header past this gate).
  """
  use ExUnit.Case, async: true
  import Bitwise, only: [bxor: 2]

  alias Cardamom.Ledger.{Header, Praos.Validation}

  @block_fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "preview_block_invalid_tx.hex"])

  # Decode the REAL header out of block 52578 (era 6).
  defp real_header do
    raw = @block_fixture |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
    {:ok, [_era, [hdr | _]], _} = CBOR.decode(raw)
    {:ok, h} = Header.decode(6, CBOR.encode(hdr))
    h
  end

  test "a REAL block's operational cert verifies (:ok)" do
    assert Validation.verify_ocert(real_header()) == :ok
  end

  # ---- REJECTION: tampering ANY input to the cold-key signature must fail ----

  test "REJECT: a flipped byte in the opcert signature (sigma)" do
    h = real_header()
    <<b0, rest::binary>> = h.operational_cert.sigma
    bad = %{h | operational_cert: %{h.operational_cert | sigma: <<bxor(b0, 1), rest::binary>>}}
    assert {:invalid, :ocert_bad_cold_signature} = Validation.verify_ocert(bad)
  end

  test "REJECT: a tampered hot_vkey (the signature no longer covers it)" do
    h = real_header()
    <<b0, rest::binary>> = h.operational_cert.hot_vkey
    bad = %{h | operational_cert: %{h.operational_cert | hot_vkey: <<bxor(b0, 1), rest::binary>>}}
    assert {:invalid, :ocert_bad_cold_signature} = Validation.verify_ocert(bad)
  end

  test "REJECT: a bumped sequence_number (counter is in the signed bytes)" do
    h = real_header()
    bad = %{h | operational_cert: %{h.operational_cert | sequence_number: h.operational_cert.sequence_number + 1}}
    assert {:invalid, :ocert_bad_cold_signature} = Validation.verify_ocert(bad)
  end

  test "REJECT: a changed kes_period (also in the signed bytes)" do
    h = real_header()
    bad = %{h | operational_cert: %{h.operational_cert | kes_period: h.operational_cert.kes_period + 1}}
    assert {:invalid, :ocert_bad_cold_signature} = Validation.verify_ocert(bad)
  end

  test "REJECT: a different cold key (issuer_vkey) — someone else's key can't have signed it" do
    h = real_header()
    <<b0, rest::binary>> = h.issuer_vkey
    bad = %{h | issuer_vkey: <<bxor(b0, 1), rest::binary>>}
    assert {:invalid, :ocert_bad_cold_signature} = Validation.verify_ocert(bad)
  end

  test "REJECT: malformed opcert (missing fields)" do
    h = real_header()
    assert {:invalid, :ocert_malformed} = Validation.verify_ocert(%{h | operational_cert: %{}})
  end

  test "REJECT: no opcert at all" do
    assert {:invalid, :ocert_missing} = Validation.verify_ocert(%{issuer_vkey: <<0::256>>, operational_cert: nil})
  end

  # BOUNDARY (Ramsay's point): opcert/KES sign the VALUES, not the byte encoding. A re-encoded
  # header (same values, different CBOR framing) therefore STILL PASSES opcert — but its HASH
  # differs. This is by design and documents what opcert does NOT guarantee: it does not pin the
  # canonical bytes. What catches a re-encoded header is CHAIN-CONTINUITY (Tier 1, not yet built):
  # the re-encoded hash won't match what its child names as prev_hash. This test pins the boundary
  # so it's explicit, and becomes the regression Tier 1 will later strengthen.
  test "a RE-ENCODED header (same values, different bytes) still passes opcert — but its hash differs" do
    raw = @block_fixture |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
    {:ok, [_era, [hdr | _]], _} = CBOR.decode(raw)
    orig = CBOR.encode(hdr)
    {:ok, oh} = Header.decode(6, orig)

    # Re-frame the outer [body, kes_sig] as an INDEFINITE-length array: identical values, different
    # bytes (the non-canonical-CBOR class of change that caused real bugs here).
    {:ok, [body, kes_sig], _} = CBOR.decode(orig)
    reencoded = <<0x9F>> <> CBOR.encode(body) <> CBOR.encode(kes_sig) <> <<0xFF>>
    {:ok, rh} = Header.decode(6, reencoded)

    assert rh.slot == oh.slot and rh.issuer_vkey == oh.issuer_vkey, "same values"
    assert rh.hash != oh.hash, "but a different hash (encoding is not canonical)"
    # opcert covers the values → still valid. (Only Tier 1 continuity would reject the re-encode.)
    assert Validation.verify_ocert(rh) == :ok
  end
end
