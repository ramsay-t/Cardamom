defmodule Cardamom.Ledger.HeaderTest do
  use ExUnit.Case, async: true

  # The header decoder dispatches on the header's OWN self-describing CBOR shape (header_body
  # array length: 15 = TPraos/pre-combined-VRF Praos through Babbage; 10 = combined-VRF Praos
  # from Conway), NOT on the wire era tag — which block-fetch and chain-sync number differently
  # and which doesn't line up with the 15→10 field change anyway. Byron (era 0) alone is taken by
  # the era tag, because its header is structurally different ([tag, header], not [body, sig]).

  alias Cardamom.Ledger.Header

  # Real captured Conway header: 10-field (combined VRF). This is the GROUND TRUTH for the shape.
  defp praos_raw do
    Path.join(__DIR__, "../../fixtures/preview_rollforward_praos.hex")
    |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
  end

  # Real captured pre-Conway header (15-field, two VRFs), carved from the rollforward fixture.
  defp tpraos_raw do
    raw =
      Path.join(__DIR__, "../../fixtures/preview_rollforward.hex")
      |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)

    {:ok, [2, [_era, %CBOR.Tag{value: %CBOR.Tag{value: hdr}}], _tip], _} = CBOR.decode(raw)
    hdr
  end

  defp byron_regular_raw do
    bytes = fn n -> %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(n)} end

    header = [
      764_824_073,
      bytes.(32),
      bytes.(32),
      [[100, 5], bytes.(32), 4242, bytes.(64)],
      [bytes.(4), bytes.(4)]
    ]

    CBOR.encode([1, header])
  end

  defp byron_ebb_raw do
    bytes = fn n -> %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(n)} end
    header = [764_824_073, bytes.(32), bytes.(32), [3, 999], [0]]
    CBOR.encode([0, header])
  end

  test "a 10-field (Conway/combined-VRF) header decodes as Praos — REGARDLESS of era tag" do
    # The shape decides, not the tag: try a spread of tags, all must give the Praos decode.
    for tag <- [4, 5, 6, 7] do
      assert {:ok, h} = Header.decode(tag, praos_raw())
      assert h.block_number == 13012
      assert h.vrf_result_2 == nil, "10-field → single combined VRF"
    end
  end

  test "a 15-field (pre-Conway) header decodes as TPraos/Shelley — REGARDLESS of era tag" do
    for tag <- [1, 4, 5, 6] do
      assert {:ok, h} = Header.decode(tag, tpraos_raw())
      assert h.vrf_result_2 != nil, "15-field → two VRF certs"
    end
  end

  test "era 0 → Byron decoder (regular header; slot flattened to absolute)" do
    assert {:ok, h} = Header.decode(0, byron_regular_raw())
    assert h.block_number == 4242
    assert h.slot == 100 * 21_600 + 5
    assert h.vrf_vkey == nil
    assert h.operational_cert == nil
  end

  test "era 0 → Byron decoder (EBB / boundary header — no slot, no issuer)" do
    assert {:ok, h} = Header.decode(0, byron_ebb_raw())
    assert h.block_number == 999
    assert h.slot == nil
    assert h.issuer_vkey == nil
  end

  test "an unrecognised header-body arity is a loud error, never a guess" do
    weird = CBOR.encode([[1, 2, 3], %CBOR.Tag{tag: :bytes, value: <<0>>}])
    assert {:error, {:unknown_header_shape, 3}} = Header.decode(6, weird)
  end
end
