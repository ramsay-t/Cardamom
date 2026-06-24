defmodule Cardamom.Ledger.HeaderTest do
  use ExUnit.Case, async: true

  # The era-dispatching entry point: [era_tag] selects the per-era decoder. SPEC: HardFork
  # CardanoEras index (ouroboros-consensus Cardano/Block.hs): 0 Byron, 1-4 TPraos, 5-7 Praos.

  alias Cardamom.Ledger.Header

  defp praos_raw do
    Path.join(__DIR__, "../../fixtures/preview_rollforward_praos.hex")
    |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
  end

  defp tpraos_raw, do: Cardamom.Ledger.Conway.HeaderBuilder.build(block_number: 7, slot: 70).raw

  # A minimal but structurally-real Byron REGULAR header [1, [magic, prevHash, bodyProof,
  # [slot, genesisKey, difficulty, sig], blockVersions]] per byron Block/Header.hs.
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

  test "era 5/6/7 → Praos decoder (real fixture)" do
    for era <- [5, 6, 7] do
      assert {:ok, h} = Header.decode(era, praos_raw())
      assert h.block_number == 13012
      assert h.vrf_result_2 == nil, "era #{era} should decode as Praos (single VRF)"
    end
  end

  test "era 1-4 → TPraos (Shelley) decoder" do
    for era <- [1, 2, 3, 4] do
      assert {:ok, h} = Header.decode(era, tpraos_raw())
      assert h.block_number == 7
      # TPraos carries the second VRF cert.
      assert h.vrf_result_2 != nil, "era #{era} should decode as TPraos (two VRFs)"
    end
  end

  # A Byron EBB / boundary header [0, [magic, prevHash, bodyProof, [epoch, difficulty],
  # [genesisTag]]] per byron Block/Header.hs encCBORABoundaryHeader.
  defp byron_ebb_raw do
    bytes = fn n -> %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(n)} end
    header = [764_824_073, bytes.(32), bytes.(32), [3, 999], [0]]
    CBOR.encode([0, header])
  end

  test "era 0 → Byron decoder (regular header; slot flattened to absolute)" do
    assert {:ok, h} = Header.decode(0, byron_regular_raw())
    assert h.block_number == 4242
    # slot [epoch=100, slot_in_epoch=5] → 100*21600 + 5
    assert h.slot == 100 * 21_600 + 5
    # Byron has no VRF / opcert.
    assert h.vrf_vkey == nil
    assert h.operational_cert == nil
  end

  test "era 0 → Byron decoder (EBB / boundary header — no slot, no issuer)" do
    assert {:ok, h} = Header.decode(0, byron_ebb_raw())
    assert h.block_number == 999
    assert h.slot == nil
    assert h.issuer_vkey == nil
  end

  test "strict cross-era: a Praos body under a TPraos tag is rejected" do
    assert {:error, _} = Header.decode(4, praos_raw())
  end

  test "strict cross-era: a TPraos body under a Praos tag is rejected" do
    assert {:error, _} = Header.decode(6, tpraos_raw())
  end

  test "unknown era tag is a loud error, never a guess" do
    assert {:error, {:unknown_era, 99}} = Header.decode(99, praos_raw())
  end
end
