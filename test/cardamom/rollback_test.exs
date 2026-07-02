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

  # Await completion — extraction is async (a supervised BlockHandler + per-tx retriers), so tests
  # that assert on TXO state immediately after must wait for the handler to mark done.
  defp extract(hash \\ nil, {raw, _txid, slot}) do
    ChainStore.extract_block_sync(hash || :crypto.strong_rand_bytes(32), raw, slot)
  end

  test "rollback RESURRECTS a UTXO spent by an orphaned block" do
    # PRODUCER at slot 100: creates output (p_txid, 0).
    {_p_raw, p_txid, _} = producer = block_at(100, [], 7)
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

  test "rollback CANCELS a live handler (absent-producer block) and cleans its outputs" do
    # A block whose spend references a producer we never load → its BlockHandler stays LIVE, its
    # retrier retrying forever. This is the case the supervision tree exists for: rollback must
    # terminate that handler (killing the retrier, confirming it dead) THEN clean the block's
    # outputs — not leave a retrier writing after cleanup.
    hash = :crypto.strong_rand_bytes(32)
    absent = :crypto.strong_rand_bytes(32)
    {raw, out_txid, slot} = blk = block_at(600, [{absent, 0}], 8)
    # Store the block row (so rollback's orphan lookup finds it) and spawn the ASYNC handler.
    {:ok, _} =
      %Block{}
      |> Block.changeset(%{hash: hash, slot: slot, block_no: 600, tx_count: 1, raw: raw, txo_processed: false})
      |> Repo.insert()

    :ok = ChainStore.extract_block(hash, raw, slot)

    # The handler creates its OUTPUT (phase 1) but can never resolve its spend → stays live.
    :ok = wait_until(fn -> Repo.get_by(Txo, txid: out_txid, ix: 0) != nil end)
    assert [{handler_pid, _}] = Registry.lookup(Cardamom.Ledger.BlockRegistry, hash)
    assert Process.alive?(handler_pid), "handler stays live retrying the unresolvable spend"

    # ROLLBACK past the block's slot: terminate the handler (kill retrier, confirm dead), clean.
    {:ok, _summary} = ChainStore.rollback(550)

    refute Process.alive?(handler_pid), "rollback terminated the live handler"
    refute Repo.get_by(Txo, txid: out_txid, ix: 0), "the orphaned block's output was cleaned up"
    assert Registry.lookup(Cardamom.Ledger.BlockRegistry, hash) == [], "handler deregistered"
  end

  defp wait_until(check, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> :ok end)
    |> Enum.reduce_while(nil, fn _, _ ->
      cond do
        check.() -> {:halt, :ok}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, :timeout}
        true -> Process.sleep(20); {:cont, nil}
      end
    end)
  end
end
