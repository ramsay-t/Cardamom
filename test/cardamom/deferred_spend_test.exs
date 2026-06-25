defmodule Cardamom.DeferredSpendTest do
  @moduledoc """
  Cross-block out-of-order spends + crash recovery for the CONFIRMED UTxO set, exercised
  through the REAL public path (build era-6 blocks, run process_block).

  When a block spends a UTxO whose producing block hasn't been ingested yet (out-of-order /
  concurrent range backfill), spend_each spawns a retrier that keeps trying until the producer
  arrives, then dies. Those retriers don't survive a restart, so reconcile_unprocessed_blocks
  re-processes any block whose TXOs weren't fully extracted, self-healing dangling spends.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Block
  alias Cardamom.Store.Txo

  # An era-6 block [6, [header, tx_bodies, wits, aux, invalid]] with one tx body.
  defp block(tx_body) do
    inner = [<<0xF6>>, [tx_body], [], %{}, []]
    CBOR.encode([6, inner])
  end

  # A tx body that creates one output and spends the given inputs (list of {txid, ix}).
  defp body(inputs, output_tag) do
    ins = for {t, i} <- inputs, do: [%CBOR.Tag{tag: :bytes, value: t}, i]
    out = [%CBOR.Tag{tag: :bytes, value: <<output_tag>>}, 1_000_000]
    %{0 => ins, 1 => [out]}
  end

  # Build a block, then ask the decoder what txid it produced (blake2b of the body bytes), so a
  # later block can reference (txid, 0).
  defp block_and_txid(inputs, output_tag) do
    raw = block(body(inputs, output_tag))
    {:ok, [tx]} = Block.txs_in(raw)
    {raw, tx.txid}
  end

  test "out-of-order: a spend whose producer arrives LATER resolves on the next reconcile" do
    # PRODUCER: no inputs, one output. Learn its txid so the spender can reference (txid, 0).
    {producer_raw, producer_txid} = block_and_txid([], 7)
    # SPENDER: spends (producer_txid, 0).
    {spender_raw, spender_txid} = block_and_txid([{producer_txid, 0}], 9)
    spender_hash = :crypto.strong_rand_bytes(32)

    # Store the spender block row, then extract it FIRST — its input has no producer yet →
    # deferred → extract_block leaves it txo_processed=0 (no spawned watcher; the reconciler is
    # the retry loop). The block row must exist so the reconciler can re-run it later.
    store_block(spender_hash, 2, spender_raw)
    :ok = ChainStore.extract_block(spender_hash, spender_raw)
    refute Repo.get_by(Txo, txid: producer_txid, ix: 0), "producer output shouldn't exist yet"
    assert pending?(spender_hash), "spender stays pending until its producer arrives"

    # Now the PRODUCER arrives → its output (producer_txid, 0) is created.
    ChainStore.extract_block(:crypto.strong_rand_bytes(32), producer_raw)

    # The reconciler's sweep re-runs the still-pending spender block; now the producer's output
    # exists, so the deferred spend applies and the block marks done.
    ChainStore.reconcile_unprocessed_blocks()

    txo = Repo.get_by(Txo, txid: producer_txid, ix: 0)
    assert txo, "producer output should exist once its block processed"
    assert txo.spent_by == spender_txid, "the deferred spend resolves on the reconcile after the producer arrives"
    refute pending?(spender_hash), "spender is marked done once its spend resolved"
  end

  defp store_block(hash, block_no, raw) do
    {:ok, _} =
      %Cardamom.Store.Block{}
      |> Cardamom.Store.Block.changeset(%{hash: hash, slot: block_no, block_no: block_no, tx_count: 1, raw: raw, txo_processed: false})
      |> Repo.insert()
  end

  defp pending?(hash), do: Repo.get(Cardamom.Store.Block, hash).txo_processed == false

  test "crash recovery: reconcile re-processes an un-extracted block and heals a dangling spend" do
    {producer_raw, producer_txid} = block_and_txid([], 7)
    {spender_raw, spender_txid} = block_and_txid([{producer_txid, 0}], 9)

    # Producer fully processed: output exists, unspent.
    :ok = ChainStore.process_block(producer_raw)
    assert %{spent_by: nil} = Repo.get_by(Txo, txid: producer_txid, ix: 0)

    # Simulate the post-CRASH state: the spender block was stored raw but its TXOs were NEVER
    # extracted (txo_processed=false). Store the block row directly; the reconciler heals it.
    {:ok, _} =
      %Cardamom.Store.Block{}
      |> Cardamom.Store.Block.changeset(%{
        hash: :crypto.strong_rand_bytes(32),
        slot: 2,
        block_no: 2,
        tx_count: 1,
        raw: spender_raw,
        txo_processed: false
      })
      |> Repo.insert()

    # Recovery: reconcile re-processes the un-extracted block, applying the dangling spend.
    assert ChainStore.reconcile_unprocessed_blocks() >= 1

    txo = Repo.get_by(Txo, txid: producer_txid, ix: 0)
    assert txo.spent_by == spender_txid, "reconcile should have applied the dangling spend"
  end
end
