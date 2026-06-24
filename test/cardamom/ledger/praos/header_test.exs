defmodule Cardamom.Ledger.Praos.HeaderTest do
  use ExUnit.Case, async: true

  # SPEC: ouroboros-consensus-protocol Praos/Header.hs EncCBOR (HeaderBody) — the nested
  # 10-field combined-VRF header body (eras 5 Babbage / 6 Conway / 7 Dijkstra). The fixture is a
  # REAL era-5 RollForward header captured from Preview (block 13012 — the exact block the old
  # 15-field decoder rejected, freezing the chain at 13011).

  alias Cardamom.Ledger.Praos.Header

  @fixture Path.join(__DIR__, "../../../fixtures/preview_rollforward_praos.hex")

  defp raw, do: @fixture |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)

  test "decodes a real Preview era-5 Praos header (the live-bug block)" do
    assert {:ok, h} = Header.decode(raw())
    assert h.block_number == 13012
    assert h.slot == 259215
    # Praos has ONE VRF cert; the second is nil.
    assert is_list(h.vrf_result)
    assert h.vrf_result_2 == nil
    # nested OCert decoded into the map.
    assert is_integer(h.operational_cert.sequence_number)
    assert {major, minor} = h.protocol_version
    assert is_integer(major) and is_integer(minor)
    # 32-byte identity hash, real blake2b-256 of the raw bytes.
    assert byte_size(h.hash) == 32
    assert h.hash == Cardamom.Crypto.blake2b_256(raw())
    assert h.raw_size == byte_size(raw())
  end

  test "strict — a flat 15-field (TPraos) body is rejected, not coerced" do
    # Build a 15-field TPraos body (what HeaderBuilder makes) and feed it to the Praos decoder:
    # it must refuse it (the shapes are genuinely different).
    tpraos = Cardamom.Ledger.Conway.HeaderBuilder.build(block_number: 1, slot: 1)
    assert {:error, {:bad_praos_header_body, _}} = Header.decode(tpraos.raw)
  end

  test "strict — wrong-arity body is rejected" do
    raw = CBOR.encode([[1, 2, 3], %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(448)}])
    assert {:error, {:bad_praos_header_body, _}} = Header.decode(raw)
  end

  test "non-binary input is rejected, never raises" do
    assert {:error, :not_binary} = Header.decode(:nope)
  end
end
