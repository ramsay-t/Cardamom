defmodule Cardamom.BlockFetch.GetBlocksTest do
  @moduledoc """
  End-to-end block-fetch: ChainStore.get_blocks issues a RANGE request over a real
  bearer to a (strict) SimPeer serving real-shaped blocks, verifies each block's body
  against its header's block_body_hash, stores the valid ones, and returns them in
  order. Also: a tampered block served by the peer is REJECTED (not stored), proving
  the trust boundary is at ingest.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{Channel, ChainStore, Connection, BlockFetch}
  alias Cardamom.Ledger.Conway.BlockBuilder
  alias Cardamom.Store.Block, as: BlockRow

  # Stand up: SimPeer (block-fetch responder, strict) <-> bearer <-> BlockFetch.Client.
  defp stack(blocks) do
    {client_end, server_end} = Channel.Test.pair()
    {:ok, _sim} = Cardamom.SimPeer.start_link(channel: server_end, protocols: [:block_fetch], blocks: blocks)
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "bf")
    {:ok, bf} = BlockFetch.Client.start_link(conn: conn, peer: "bf")
    :ok = ChainStore.register_peer(bf)
    bf
  end

  test "get_blocks fetches a RANGE, verifies bodies, stores, and returns in order" do
    # Three real-shaped blocks at slots 100/200/300, correct body-hash commitments.
    bs = for {bn, sl} <- [{1, 100}, {2, 200}, {3, 300}], do: BlockBuilder.build(block_number: bn, slot: sl, tx_count: 2)
    _bf = stack(bs)

    points = Enum.map(bs, fn b -> [b.slot, b.header_hash] end)

    result = ChainStore.get_blocks(points)

    # All three returned, in order, as {:ok, row}.
    assert length(result) == 3
    assert Enum.all?(result, &match?({:ok, %BlockRow{}}, &1))
    assert Enum.map(result, fn {:ok, r} -> r.slot end) == [100, 200, 300]

    # And durably stored (verified) — a second get_blocks is a pure cache/SQLite hit.
    for b <- bs, do: assert %BlockRow{} = ChainStore.stored_block(b.header_hash)
  end

  test "a tampered block (body-hash mismatch) is NOT stored → reported :unavailable" do
    good = BlockBuilder.build(block_number: 1, slot: 100, tx_count: 2)

    # Tamper the served block's body bytes but keep its (now-mismatched) header hash
    # as the identity we request — the relay is 'lying' about the body.
    raw = good.raw
    flip_at = good.bodies_offset + 6
    <<head::binary-size(flip_at), 0x01, tail::binary>> = raw
    tampered_raw = <<head::binary, 0x00, tail::binary>>
    tampered = %{good | raw: tampered_raw, envelope: %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: tampered_raw}}}

    _bf = stack([tampered])
    point = [good.slot, good.header_hash]
    [result] = ChainStore.get_blocks([point])

    # The sink (verify_and_store) rejects the tampered body, so it never lands in the
    # store → get_blocks reports it :unavailable. (Peer-striking for the lie is a
    # separate handler concern; see project_cardamom_blockfetch_design.)
    assert {:unavailable, ^point} = result
    assert ChainStore.stored_block(good.header_hash) == nil, "tampered block must not be stored"
  end

  test "get_blocks returns already-stored blocks without re-fetching" do
    b = BlockBuilder.build(block_number: 1, slot: 100, tx_count: 1)
    {:ok, decoded} = Cardamom.Ledger.Conway.Block.decode(b.raw)
    {:ok, _} = ChainStore.put_block(decoded)

    # No SimPeer needed — it's already in the store; pass a dummy client we never call.
    [result] = ChainStore.get_blocks([[b.slot, b.header_hash]])
    assert {:ok, %BlockRow{slot: 100}} = result
  end
end
