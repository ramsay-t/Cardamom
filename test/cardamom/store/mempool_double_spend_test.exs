defmodule Cardamom.Store.MempoolDoubleSpendTest do
  @moduledoc """
  Two pending txs that spend the SAME confirmed UTxO — both are legitimately in the
  mempool (a mempool conflict / replace-by-fee situation; neither is intrinsically
  invalid). When a block confirms ONE of them, the chain resolves the conflict:

    * the confirmed tx leaves the mempool :in_block (it's now on chain);
    * the OTHER (which wanted the same input) is out-competed → :inputs_spent.

  We don't know in advance which the block picks, so we match txids to decide which
  verdict each got. This is the separation/cascade linkage doing its job: the block
  spends UTxO X, mempool_spenders_of(X) finds BOTH pending txs, the confirmed one is
  promoted and the loser evicted.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Conway.Tx

  defp b(x), do: %CBOR.Tag{tag: :bytes, value: x}

  # A tx spending UTxO (in_txid, in_ix) and creating one distinct output (id varies the txid).
  defp conflicting_tx(in_txid, in_ix, out_marker) do
    body = CBOR.encode(%{0 => [[b(in_txid), in_ix]], 1 => [[b(out_marker), 1_000]]})
    {:ok, tx} = Tx.decode_tx(body)
    tx
  end

  # A block containing exactly the given tx body bytes (one valid tx).
  defp block_with_tx(body_bytes) do
    inner =
      <<0x85>> <> CBOR.encode(%{}) <> CBOR.encode([elem(CBOR.decode(body_bytes), 1)]) <>
        CBOR.encode([]) <> CBOR.encode([]) <> CBOR.encode([])

    <<0x82>> <> CBOR.encode(4) <> inner
  end

  test "two mempool txs spend one UTxO; the block winner leaves :in_block, the loser :inputs_spent" do
    shared = <<42::256>>

    # Seed the contested UTxO into the confirmed set (unspent).
    {:ok, _} = Cardamom.Store.Repo.insert(%Cardamom.Store.Txo{txid: shared, ix: 0, value: 9_000_000})

    # Two distinct txs, both spending shared#0. Both are valid to ENTER the mempool —
    # a conflict is only resolved by the chain, not at mempool-entry.
    tx_a = conflicting_tx(shared, 0, <<0xA1>>)
    tx_b = conflicting_tx(shared, 0, <<0xB2>>)
    refute tx_a.txid == tx_b.txid, "the two txs are distinct"

    :ok = ChainStore.put_mempool_tx(tx_a)
    :ok = ChainStore.put_mempool_tx(tx_b)

    # Both present in the mempool, both recorded as spenders of shared#0.
    assert ChainStore.mempool_txo(tx_a.txid, 0) != nil
    assert ChainStore.mempool_txo(tx_b.txid, 0) != nil

    spenders = ChainStore.mempool_spenders_of(shared, 0) |> MapSet.new(& &1.spender_txid)
    assert MapSet.member?(spenders, tx_a.txid)
    assert MapSet.member?(spenders, tx_b.txid)

    # The next block contains tx_a (it won the race). Process it.
    body_a = CBOR.encode(%{0 => [[b(shared), 0]], 1 => [[b(<<0xA1>>), 1_000]]})
    :ok = ChainStore.process_block(block_with_tx(body_a))

    # Resolve by matching hashes: tx_a confirmed (:in_block); tx_b out-competed (:inputs_spent).
    assert ChainStore.mempool_txo(tx_a.txid, 0) == nil, "the winner left the mempool"
    assert ChainStore.mempool_txo(tx_b.txid, 0) == nil, "the loser left the mempool"

    assert [%{reason: "in_block"}] =
             ChainStore.mempool_graveyard(tx_a.txid) |> Enum.filter(&(&1.ix == 0)),
           "the tx the block confirmed leaves :in_block"

    assert [%{reason: "inputs_spent"}] =
             ChainStore.mempool_graveyard(tx_b.txid) |> Enum.filter(&(&1.ix == 0)),
           "the conflicting tx (input taken) leaves :inputs_spent"

    # And the contested UTxO is now spent by the winner.
    assert %{spent_by: winner} = ChainStore.txo(shared, 0)
    assert winner == tx_a.txid
  end

  test "the OTHER way round: when the block confirms tx_b, IT leaves :in_block and tx_a :inputs_spent" do
    # Same setup, but the block contains tx_b — proves the verdict follows the HASH, not
    # the insertion order / list position (we're not just promoting the first tx).
    shared = <<43::256>>
    {:ok, _} = Cardamom.Store.Repo.insert(%Cardamom.Store.Txo{txid: shared, ix: 0, value: 9_000_000})

    tx_a = conflicting_tx(shared, 0, <<0xA1>>)
    tx_b = conflicting_tx(shared, 0, <<0xB2>>)
    :ok = ChainStore.put_mempool_tx(tx_a)
    :ok = ChainStore.put_mempool_tx(tx_b)

    # The block confirms tx_b this time.
    body_b = CBOR.encode(%{0 => [[b(shared), 0]], 1 => [[b(<<0xB2>>), 1_000]]})
    :ok = ChainStore.process_block(block_with_tx(body_b))

    # Verdicts must be SWAPPED vs the first test.
    assert [%{reason: "in_block"}] =
             ChainStore.mempool_graveyard(tx_b.txid) |> Enum.filter(&(&1.ix == 0)),
           "tx_b is the one the block confirmed → :in_block"

    assert [%{reason: "inputs_spent"}] =
             ChainStore.mempool_graveyard(tx_a.txid) |> Enum.filter(&(&1.ix == 0)),
           "tx_a is now the loser → :inputs_spent"

    assert %{spent_by: winner} = ChainStore.txo(shared, 0)
    assert winner == tx_b.txid, "the UTxO is spent by tx_b, not tx_a"
  end

  # Belt-and-braces: run BOTH directions in a parameterised loop so the symmetry is
  # explicit — whichever tx the block picks gets :in_block, the other :inputs_spent.
  for {winner_marker, loser_marker, label} <- [{<<0xA1>>, <<0xB2>>, "A wins"}, {<<0xB2>>, <<0xA1>>, "B wins"}] do
    test "either tx can win — block picks #{label}" do
      shared = :crypto.strong_rand_bytes(32)
      {:ok, _} = Cardamom.Store.Repo.insert(%Cardamom.Store.Txo{txid: shared, ix: 0, value: 9_000_000})

      tx_win = conflicting_tx(shared, 0, unquote(winner_marker))
      tx_lose = conflicting_tx(shared, 0, unquote(loser_marker))
      :ok = ChainStore.put_mempool_tx(tx_win)
      :ok = ChainStore.put_mempool_tx(tx_lose)

      body = CBOR.encode(%{0 => [[b(shared), 0]], 1 => [[b(unquote(winner_marker)), 1_000]]})
      :ok = ChainStore.process_block(block_with_tx(body))

      assert [%{reason: "in_block"}] = ChainStore.mempool_graveyard(tx_win.txid) |> Enum.filter(&(&1.ix == 0))
      assert [%{reason: "inputs_spent"}] = ChainStore.mempool_graveyard(tx_lose.txid) |> Enum.filter(&(&1.ix == 0))
    end
  end
end
