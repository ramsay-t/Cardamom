defmodule Cardamom.Store.MempoolTxoTest do
  @moduledoc """
  The mempool TXO store — SPECULATIVE outputs from pending (mempool) txs, kept in a
  SEPARATE table with an IDENTICAL schema to confirmed `txos`. Structure is the
  guarantee: if a row is in `txos` it is ON CHAIN (settled, block-only); if it's in
  `mempool_txos` it is PENDING. No WHERE-filter to forget — the table you read IS the
  verdict. JOINs across the two (identical columns) "just work" when validating mempool
  actions against the chain (e.g. does this pending tx spend a real confirmed UTXO?).

  Lifecycle differs by design: confirmed TXOs are block-only + UPSERT (immutable history,
  re-runnable); mempool TXOs support ADD and DELETE (a pending tx is dropped when it
  confirms, is replaced, or expires) — deletes move to a GRAVEYARD for forensics.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Conway.Tx

  defp fixture(n) do
    Path.join([__DIR__, "..", "..", "fixtures", "blocks", "block-#{n}.hex"])
    |> File.read!()
    |> String.trim()
    |> Base.decode16!(case: :lower)
  end

  defp tx(n) do
    {:ok, [t]} = Tx.txs_in(fixture(n))
    t
  end

  test "a pending tx's outputs go to the MEMPOOL table, not the confirmed txos table" do
    t = tx(3)
    :ok = ChainStore.put_mempool_tx(t)

    # In the mempool space...
    assert %{spent_by: nil} = ChainStore.mempool_txo(t.txid, 0)
    # ...and NOT leaking into the confirmed chain space (the structural guarantee).
    assert ChainStore.txo(t.txid, 0) == nil, "a pending output must not appear as confirmed"
  end

  test "deleting a mempool tx removes its outputs and moves them to the graveyard" do
    t = tx(3)
    :ok = ChainStore.put_mempool_tx(t)
    assert %{} = ChainStore.mempool_txo(t.txid, 0)

    :ok = ChainStore.drop_mempool_tx(t.txid, :replaced)

    assert ChainStore.mempool_txo(t.txid, 0) == nil, "dropped tx is gone from the live mempool"
    # The graveyard retains it for forensics, tagged with WHY it left.
    assert [%{txid: gtxid, reason: "replaced"}] =
             ChainStore.mempool_graveyard(t.txid) |> Enum.filter(&(&1.ix == 0))
    assert gtxid == t.txid
  end

  test "JOIN: a pending tx spending a CONFIRMED utxo can be validated against the chain" do
    # Confirm block 3 → its output 0 is a real on-chain UTXO.
    :ok = ChainStore.process_block(fixture(3))
    t3 = tx(3)

    # Block 16's tx is "pending" in the mempool; it spends t3#0 (a confirmed UTXO).
    t16 = tx(16)
    :ok = ChainStore.put_mempool_tx(t16)

    # Validation question: do this pending tx's inputs reference confirmed, UNSPENT
    # chain UTXOs? Resolve each input against the txos table (the JOIN-shaped query).
    [{src_txid, src_ix}] = t16.inputs
    confirmed = ChainStore.txo(src_txid, src_ix)
    assert confirmed != nil, "the input resolves to a real confirmed UTXO"
    assert confirmed.txid == t3.txid and confirmed.spent_by == nil,
           "and that confirmed UTXO is unspent — the pending spend is valid against the chain"
  end

  test "evict_mempool_tx: the two lifecycle exits (:in_block, :invalidated)" do
    a = tx(3)
    b = tx(16)
    :ok = ChainStore.put_mempool_tx(a)
    :ok = ChainStore.put_mempool_tx(b)

    :ok = ChainStore.evict_mempool_tx(a.txid, :in_block)
    :ok = ChainStore.evict_mempool_tx(b.txid, :invalidated)

    assert ChainStore.mempool_txo(a.txid, 0) == nil
    assert ChainStore.mempool_txo(b.txid, 0) == nil

    assert [%{reason: "in_block"}] = ChainStore.mempool_graveyard(a.txid) |> Enum.filter(&(&1.ix == 0))
    assert [%{reason: "invalidated"}] = ChainStore.mempool_graveyard(b.txid) |> Enum.filter(&(&1.ix == 0))
  end

  test "evict_mempool_tx rejects a non-lifecycle reason" do
    assert_raise FunctionClauseError, fn -> ChainStore.evict_mempool_tx(tx(3).txid, :whatever) end
  end

  test "when a pending tx CONFIRMS in a block, the chain space gains it (mempool can drop it)" do
    t = tx(16)
    :ok = ChainStore.put_mempool_tx(t)
    refute ChainStore.txo(t.txid, 0), "not yet on chain"

    # The tx lands in a block (here, block 16 IS that block) → process_block promotes it
    # into the confirmed txos table. The mempool entry can then be dropped (confirmed).
    :ok = ChainStore.process_block(fixture(16))
    assert %{spent_by: nil} = ChainStore.txo(t.txid, 0), "now confirmed on chain"

    :ok = ChainStore.drop_mempool_tx(t.txid, :confirmed)
    assert ChainStore.mempool_txo(t.txid, 0) == nil
  end
end
