defmodule Cardamom.RollbackTest do
  @moduledoc """
  ROLLBACK (reorg) of the confirmed UTxO set — the feature that makes Cardamom a true chain
  FOLLOWER, not just a forward downloader. When the relay rolls us back to a point, everything
  above it is undone: outputs created above the point are deleted, and — the case that matters
  most — UTXOs SPENT by a now-orphaned block are RESURRECTED (un-spent). Orphaned blocks move to
  the graveyard for forensics.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Block, as: LBlock
  alias Cardamom.Store.{Repo, Txo, Block, BlockGraveyard}

  # Build an era-6 block with one tx (inputs + one output), at a given slot. Returns {raw, txid}.
  defp block_at(slot, inputs, output_tag) do
    ins = for {t, i} <- inputs, do: [%CBOR.Tag{tag: :bytes, value: t}, i]
    out = [%CBOR.Tag{tag: :bytes, value: <<output_tag>>}, 1_000_000]
    body = %{0 => ins, 1 => [out]}
    inner = [<<0xF6>>, [body], [], %{}, []]
    raw = CBOR.encode([6, inner])
    {:ok, [tx]} = LBlock.txs_in(raw)
    {raw, tx.txid, slot}
  end

  defp extract(hash \\ nil, {raw, _txid, slot}) do
    ChainStore.extract_block(hash || :crypto.strong_rand_bytes(32), raw, slot)
  end

  test "rollback RESURRECTS a UTXO spent by an orphaned block" do
    # PRODUCER at slot 100: creates output (p_txid, 0).
    {p_raw, p_txid, _} = producer = block_at(100, [], 7)
    extract(producer)
    assert %{spent_by: nil} = Repo.get_by(Txo, txid: p_txid, ix: 0), "producer output starts unspent"

    # SPENDER at slot 200: spends (p_txid, 0). Now the producer output is spent.
    spender = block_at(200, [{p_txid, 0}], 9)
    {_s_raw, s_txid, _} = spender
    extract(spender)
    spent = Repo.get_by(Txo, txid: p_txid, ix: 0)
    assert spent.spent_by == s_txid, "producer output is spent by the spender"
    assert spent.spent_slot == 200

    # ROLLBACK to slot 150 — past the spender (200) but keeping the producer (100).
    {:ok, summary} = ChainStore.rollback(150)
    assert summary.resurrected >= 1

    # The producer output is RESURRECTED: unspent again.
    back = Repo.get_by(Txo, txid: p_txid, ix: 0)
    assert back, "producer output still exists (created below the rollback point)"
    assert back.spent_by == nil, "the spend was rolled back — UTXO resurrected"
    assert back.spent_slot == nil
  end

  test "rollback DELETES outputs created by an orphaned block" do
    above = block_at(300, [], 5)
    {_raw, above_txid, _} = above
    extract(above)
    assert Repo.get_by(Txo, txid: above_txid, ix: 0), "output exists before rollback"

    {:ok, summary} = ChainStore.rollback(250)
    assert summary.deleted >= 1
    refute Repo.get_by(Txo, txid: above_txid, ix: 0), "output created above the point is deleted"
  end

  test "rollback GRAVEYARDS orphaned blocks (forensic record of the lost fork)" do
    hash = :crypto.strong_rand_bytes(32)
    {raw, _txid, slot} = blk = block_at(400, [], 3)
    # Store the block row so rollback can move it (extract alone doesn't store the block row).
    {:ok, _} =
      %Block{}
      |> Block.changeset(%{hash: hash, slot: slot, block_no: 400, tx_count: 1, raw: raw, txo_processed: true})
      |> Repo.insert()

    extract(hash, blk)
    {:ok, summary} = ChainStore.rollback(350)

    assert summary.graveyarded >= 1
    refute Repo.get(Block, hash), "orphaned block removed from the live set"
    grave = Repo.get(BlockGraveyard, hash)
    assert grave, "orphaned block kept in the graveyard"
    assert grave.rolled_back_to_slot == 350
  end

  test "rollback is idempotent — rolling back again past the same point is a no-op" do
    extract(block_at(500, [], 1))
    {:ok, _} = ChainStore.rollback(450)
    {:ok, summary2} = ChainStore.rollback(450)
    assert summary2 == %{resurrected: 0, deleted: 0, graveyarded: 0}
  end
end
