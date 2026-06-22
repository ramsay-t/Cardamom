defmodule Cardamom.BlockFetch.CaptureTest do
  @moduledoc """
  The raw bytes of a fetched block are captured COMPLETELY in the durable store
  (blocks.raw), verbatim and hash-verified — that IS the forensic record. We do NOT
  log raw block bytes: a block is multi-KB, over Logger's 8192-byte truncation, so a
  log line would be an incomplete half-capture (and a disk flood at multi-peer scale).
  Early on the raw-byte log helped debug decode against the wire; now the DB holds the
  complete bytes, so the log duplication is removed. This test pins the real capture.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{Channel, ChainStore, Connection, BlockFetch}
  alias Cardamom.Ledger.Conway.BlockBuilder

  test "a fetched block's COMPLETE raw bytes land verbatim in blocks.raw" do
    blk = BlockBuilder.build(block_number: 9, slot: 999, tx_count: 2)

    {client_end, server_end} = Channel.Test.pair()
    {:ok, _sim} = Cardamom.SimPeer.start_link(channel: server_end, protocols: [:block_fetch], blocks: [blk])
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "bf-cap")
    {:ok, bf} = BlockFetch.Client.start_link(conn: conn, peer: "bf-cap")
    :ok = ChainStore.register_peer(bf)

    assert [{:ok, row}] = ChainStore.get_blocks([[blk.slot, blk.header_hash]])

    # The COMPLETE bytes are stored — not truncated, not re-encoded — byte-for-byte.
    assert row.raw == blk.raw
    assert ChainStore.stored_block(blk.header_hash).raw == blk.raw
  end
end
