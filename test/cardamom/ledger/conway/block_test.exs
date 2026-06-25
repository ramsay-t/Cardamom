defmodule Cardamom.Ledger.Conway.BlockTest do
  @moduledoc """
  Block-level decode + the SECURITY check: a header commits to its body via
  block_body_hash, so a fetched body must verify against that commitment ("you can
  attach anything to a valid header"). We build real-shaped blocks with a correct
  commitment and assert: decode extracts header/hash/tx_count; verify_body passes on
  a genuine block; verify_body FAILS if any body segment is tampered.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Conway.{Block, BlockBuilder}

  test "decode extracts the header, identity hash, and tx_count" do
    blk = BlockBuilder.build(block_number: 12, slot: 1200, tx_count: 3)

    assert {:ok, decoded} = Block.decode(blk.raw)
    assert decoded.header.block_number == 12
    assert decoded.header.slot == 1200
    assert decoded.hash == blk.header_hash, "block identity = its header hash"
    assert decoded.tx_count == 3
    assert decoded.raw == blk.raw, "verbatim bytes kept"
  end


  test "verify_body PASSES for a genuine block (body matches header commitment)" do
    blk = BlockBuilder.build(block_number: 5, slot: 500, tx_count: 2)
    {:ok, decoded} = Block.decode(blk.raw)

    assert :ok = Block.verify_body(decoded)
  end

  test "verify_body works for an empty block (tx_count 0)" do
    blk = BlockBuilder.build(block_number: 0, slot: 0, tx_count: 0)
    {:ok, decoded} = Block.decode(blk.raw)
    assert :ok = Block.verify_body(decoded)
  end

  test "verify_body FAILS when the body is tampered (the 'attach anything' attack)" do
    blk = BlockBuilder.build(block_number: 7, slot: 700, tx_count: 2)
    {:ok, decoded} = Block.decode(blk.raw)
    assert :ok = Block.verify_body(decoded)

    # Tamper a byte INSIDE a tx body value (keeps the block structurally decodable,
    # but changes body content) — the header's committed block_body_hash is unchanged,
    # so the body-hash check must catch the mismatch. We flip a byte just after the
    # header (in the bodies segment); the tx_count>0 block has real body bytes there.
    # bodies = [%{0=>0}, %{0=>1}] -> CBOR `82 A1 00 00 A1 00 01`. Flip the final value
    # byte (the `01`) to `00`: still valid CBOR (%{0=>0}) so the block stays
    # decodable, but body content changed -> the header's committed block_body_hash
    # no longer matches. This exercises verify_body specifically (not a CBOR break).
    raw = decoded.raw
    flip_at = blk.bodies_offset + 6
    <<head::binary-size(flip_at), 0x01, tail::binary>> = raw
    tampered_raw = <<head::binary, 0x00, tail::binary>>

    {:ok, tampered} = Block.decode(tampered_raw)
    assert {:error, {:body_hash_mismatch, _expected, _got}} = Block.verify_body(tampered)
  end

  test "decode rejects non-block bytes (strict, no raise)" do
    assert {:error, _} = Block.decode(<<0xFF, 0xFF>>)
    assert {:error, :not_binary} = Block.decode(:nope)
  end
end
