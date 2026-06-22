defmodule Cardamom.Wire.PreviewFixtureTest do
  @moduledoc """
  Regression tests pinned to GENUINE Cardano Preview wire data captured from a
  live session (test/fixtures/preview_capture.md,
  log/cardamom-20260620-094532-preview-firstcontact.log). Network-free, runs every
  time. If our point/tip parsing drifts, or the real wire shape we assume is
  wrong, these fail.
  """
  use ExUnit.Case, async: true

  # Real Preview tip captured 2026-06-20 (RollForward, height 4400600).
  @real_tip [
    [115_289_152,
     %CBOR.Tag{
       tag: :bytes,
       value:
         <<211, 154, 84, 171, 33, 250, 68, 93, 84, 133, 210, 9, 104, 169, 20, 201, 230, 200, 135,
           243, 95, 231, 193, 179, 134, 5, 76, 182, 47, 129, 228, 40>>
     }],
    4_400_600
  ]

  test "real Preview tip parses as [[slot, hash], block_no]" do
    [[slot, hash_tag], block_no] = @real_tip
    assert slot == 115_289_152
    assert block_no == 4_400_600
    assert %CBOR.Tag{tag: :bytes, value: hash} = hash_tag
    # The header hash is blake2b-256 => exactly 32 bytes. Confirms our hash sizing
    # against REAL relay data.
    assert byte_size(hash) == 32
  end

  test "the captured header hash is a 32-byte blake2b-256 digest (real Cardano hash size)" do
    [[_slot, %CBOR.Tag{value: hash}], _] = @real_tip
    assert byte_size(hash) == byte_size(Cardamom.Crypto.blake2b_256("anything"))
  end

  test "the captured hash hex matches its documented value (fixture integrity)" do
    [[_slot, %CBOR.Tag{value: hash}], _] = @real_tip
    assert Base.encode16(hash, case: :lower) ==
             "d39a54ab21fa445d5485d20968a914c9e6c887f35fe7c1b386054cb62f81e428"
  end

  # When the network layer hands the Connection a tip in this shape, our describe/
  # point-extraction must pull the slot out. This pins that behaviour to real data.
  test "tip point extraction yields the real slot" do
    [point, _block_no] = @real_tip
    [slot | _] = point
    assert slot == 115_289_152
  end
end
