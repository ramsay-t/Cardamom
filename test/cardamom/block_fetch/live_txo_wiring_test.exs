defmodule Cardamom.BlockFetch.LiveTxoWiringTest do
  @moduledoc """
  REGRESSION: the live block-fetch path must extract TXOs, not just store the block. For
  a long time verify_and_store only put_block'd — the whole UTxO/mempool engine (goal b)
  was built and tested but NOT fed by real incoming blocks. This pins that fetching a real
  tx-bearing block through the actual block-fetch sink (get_blocks) populates the TXO store.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{Channel, ChainStore, Connection, BlockFetch}
  alias Cardamom.Ledger.Conway.{Block, Tx}

  defp fixture(n) do
    Path.join([__DIR__, "..", "..", "fixtures", "blocks", "block-#{n}.hex"])
    |> File.read!()
    |> String.trim()
    |> Base.decode16!(case: :lower)
  end

  test "fetching a real tx-bearing block via get_blocks populates its TXOs (not just the block row)" do
    raw = fixture(16)
    {:ok, blk} = Block.decode(raw)
    {:ok, [tx]} = Tx.txs_in(raw)

    # Stand up a SimPeer serving this real block over the real block-fetch path.
    {client_end, server_end} = Channel.Test.pair()
    sim_block = %{slot: blk.header.slot, envelope: %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: raw}}}
    {:ok, _sim} = Cardamom.SimPeer.start_link(channel: server_end, protocols: [:block_fetch], blocks: [sim_block])
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "txo-wire")
    {:ok, bf} = BlockFetch.Client.start_link(conn: conn, peer: "txo-wire")
    :ok = ChainStore.register_peer(bf)

    # Fetch it through the REAL sink (get_blocks → verify_and_store → put_block + process_block).
    [{:ok, _row}] = ChainStore.get_blocks([[blk.header.slot, blk.header.hash]])

    # The block row is stored (the old behaviour)...
    assert ChainStore.stored_block(blk.header.hash) != nil

    # ...AND its TXOs were extracted (the wiring this test pins). Block 16 has 4 outputs.
    for ix <- 0..3 do
      assert %{spent_by: nil} = ChainStore.txo(tx.txid, ix),
             "output #{ix} of the fetched block must be a TXO in the store"
    end
  end

  test "a block fetched via the live sink runs the mempool CASCADE (not just TXO extract)" do
    raw = fixture(16)
    {:ok, blk} = Block.decode(raw)
    {:ok, [blk_tx]} = Tx.txs_in(raw)

    # A PENDING mempool tx that spends the SAME input block 16's tx spends — so when
    # block 16 arrives via the live path, this pending tx is out-competed (:inputs_spent).
    bytes = fn x -> %CBOR.Tag{tag: :bytes, value: x} end
    [{shared_in_txid, shared_in_ix}] = blk_tx.inputs
    pending_body = CBOR.encode(%{0 => [[bytes.(shared_in_txid), shared_in_ix]], 1 => [[bytes.(<<0xEE>>), 9]]})
    {:ok, pending} = Tx.decode_tx(pending_body)
    :ok = ChainStore.put_mempool_tx(pending)
    assert ChainStore.mempool_txo(pending.txid, 0) != nil, "pending tx is in the mempool"

    # Fetch block 16 through the real block-fetch sink.
    {client_end, server_end} = Channel.Test.pair()
    sim_block = %{slot: blk.header.slot, envelope: %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: raw}}}
    {:ok, _sim} = Cardamom.SimPeer.start_link(channel: server_end, protocols: [:block_fetch], blocks: [sim_block])
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "casc-wire")
    {:ok, bf} = BlockFetch.Client.start_link(conn: conn, peer: "casc-wire")
    :ok = ChainStore.register_peer(bf)
    [{:ok, _}] = ChainStore.get_blocks([[blk.header.slot, blk.header.hash]])

    # The cascade fired on the live path: the out-competed pending tx is gone, graveyarded.
    assert ChainStore.mempool_txo(pending.txid, 0) == nil, "live block must cascade-evict the conflicting pending tx"
    assert [%{reason: "inputs_spent"}] = ChainStore.mempool_graveyard(pending.txid) |> Enum.filter(&(&1.ix == 0))
  end
end
