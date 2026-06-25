defmodule Cardamom.Store.MempoolSixWayConflictTest do
  @moduledoc """
  SIX pending txs all spend the SAME confirmed UTxO (an extreme conflict — six racers for
  one input). When a block confirms ONE, the cascade must catch EVERY OTHER spender, not
  just the first it finds: the winner leaves :in_block, all FIVE losers leave :inputs_spent.
  This pins that mempool_spenders_of(X) returns the whole set and the cascade evicts all of
  them (the separation linkage finding every dependent of X).
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Conway.Tx

  defp b(x), do: %CBOR.Tag{tag: :bytes, value: x}

  # A tx spending (in_txid, in_ix), output marked by `n` so each txid is distinct.
  defp racer(in_txid, in_ix, n) do
    {:ok, tx} = Tx.decode_tx(CBOR.encode(%{0 => [[b(in_txid), in_ix]], 1 => [[b(<<n>>), 1_000]]}))
    tx
  end

  defp block_with_tx(body_bytes) do
    inner =
      <<0x85>> <> CBOR.encode(%{}) <> CBOR.encode([elem(CBOR.decode(body_bytes), 1)]) <>
        CBOR.encode([]) <> CBOR.encode([]) <> CBOR.encode([])

    <<0x82>> <> CBOR.encode(4) <> inner
  end

  test "six txs spend one UTxO; block confirms one, the other FIVE all leave :inputs_spent" do
    shared = <<55::256>>
    {:ok, _} = Cardamom.Store.Repo.insert(%Cardamom.Store.Txo{txid: shared, ix: 0, value: 9_000_000})

    # Six distinct txs, all spending shared#0 (output markers 1..6).
    racers = for n <- 1..6, do: racer(shared, 0, n)
    txids = Enum.map(racers, & &1.txid)
    assert length(Enum.uniq(txids)) == 6, "all six txs are distinct"

    Enum.each(racers, &(:ok = ChainStore.put_mempool_tx(&1)))

    # All six present, and all six recorded as spenders of shared#0.
    Enum.each(txids, fn t -> assert ChainStore.mempool_txo(t, 0) != nil end)
    spenders = ChainStore.mempool_spenders_of(shared, 0) |> MapSet.new()
    assert Enum.all?(txids, &MapSet.member?(spenders, &1)), "all six are spenders of the UTxO"
    assert MapSet.size(spenders) == 6

    # The block confirms racer 3 (arbitrary winner). Process it.
    winner = Enum.at(racers, 2)
    body = CBOR.encode(%{0 => [[b(shared), 0]], 1 => [[b(<<3>>), 1_000]]})
    assert winner.txid == elem(Tx.decode_tx(body), 1).txid, "the block body IS racer 3"
    _ = ChainStore.process_block(block_with_tx(body))

    # The whole mempool is now empty of these six — every racer left.
    Enum.each(txids, fn t ->
      assert ChainStore.mempool_txo(t, 0) == nil, "racer #{Base.encode16(t) |> String.slice(0, 8)} left the mempool"
    end)

    # The winner left :in_block; ALL FIVE others left :inputs_spent (none missed).
    assert [%{reason: "in_block"}] =
             ChainStore.mempool_graveyard(winner.txid) |> Enum.filter(&(&1.ix == 0))

    losers = List.delete(racers, winner)
    assert length(losers) == 5

    for loser <- losers do
      assert [%{reason: "inputs_spent"}] =
               ChainStore.mempool_graveyard(loser.txid) |> Enum.filter(&(&1.ix == 0)),
             "every loser must be evicted :inputs_spent — the cascade caught all of them"
    end

    # And no spenders remain in the edge index for that UTxO.
    assert ChainStore.mempool_spenders_of(shared, 0) == []
    # The UTxO is spent by the winner.
    assert %{spent_by: w} = ChainStore.txo(shared, 0)
    assert w == winner.txid
  end
end
