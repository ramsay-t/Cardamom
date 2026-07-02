defmodule Cardamom.DeferredSpendTest do
  @moduledoc """
  Cross-block out-of-order spends + crash recovery for the CONFIRMED UTxO set, exercised
  through the REAL public path (build era-6 blocks, run process_block).

  When a block spends a UTxO whose producing block hasn't been ingested yet (out-of-order /
  concurrent range backfill), its BlockHandler's per-tx retrier keeps retrying CONTINUOUSLY until
  the producer arrives, then the block marks done ON ITS OWN — no reconcile needed for a LIVE
  handler. reconcile_unprocessed_blocks is the CRASH BACKSTOP: it re-spawns a handler for a block
  left txo_processed=false when its handler died with the VM (retriers don't survive a restart).
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Block
  alias Cardamom.Store.Txo

  # Extraction is async (a BlockHandler + per-tx retriers). Block until `check` holds or the
  # deadline. Continuous retry means a deferred spend resolves on its own once the producer lands.
  defp eventually(check, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(check, deadline)
  end

  defp do_eventually(check, deadline) do
    cond do
      check.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> Process.sleep(20); do_eventually(check, deadline)
    end
  end

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

  test "out-of-order: a spend whose producer arrives LATER resolves on its own (continuous retry)" do
    # PRODUCER: no inputs, one output. Learn its txid so the spender can reference (txid, 0).
    {producer_raw, producer_txid} = block_and_txid([], 7)
    # SPENDER: spends (producer_txid, 0).
    {spender_raw, spender_txid} = block_and_txid([{producer_txid, 0}], 9)
    spender_hash = :crypto.strong_rand_bytes(32)

    # Store the spender block row, then extract it FIRST — its input has no producer yet. The
    # spender's BlockHandler stays LIVE, its retrier retrying continuously; the block is not done.
    store_block(spender_hash, 2, spender_raw)
    :ok = ChainStore.extract_block(spender_hash, spender_raw)
    refute Repo.get_by(Txo, txid: producer_txid, ix: 0), "producer output shouldn't exist yet"
    assert pending?(spender_hash), "spender stays pending until its producer arrives"

    # Now the PRODUCER arrives → its output (producer_txid, 0) is created. The spender's still-live
    # retrier sees it on its next tick and applies the spend — NO reconcile needed for a live handler.
    ChainStore.extract_block(:crypto.strong_rand_bytes(32), producer_raw)

    :ok = eventually(fn ->
      case Repo.get_by(Txo, txid: producer_txid, ix: 0) do
        %{spent_by: ^spender_txid} -> true
        _ -> false
      end
    end)

    txo = Repo.get_by(Txo, txid: producer_txid, ix: 0)
    assert txo.spent_by == spender_txid, "the deferred spend resolves once the producer arrives (continuous retry)"
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

    # Recovery: reconcile RE-SPAWNS a handler for the un-extracted block; its retrier applies the
    # dangling spend (the producer's output already exists). Async, so wait for it to settle.
    assert ChainStore.reconcile_unprocessed_blocks() >= 1

    :ok = eventually(fn ->
      case Repo.get_by(Txo, txid: producer_txid, ix: 0) do
        %{spent_by: ^spender_txid} -> true
        _ -> false
      end
    end)

    txo = Repo.get_by(Txo, txid: producer_txid, ix: 0)
    assert txo.spent_by == spender_txid, "reconcile-respawned handler should have applied the dangling spend"
  end
end
