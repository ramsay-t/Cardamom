defmodule Cardamom.Store.TxoTest do
  @moduledoc """
  The TXO store — every transaction output we've seen, keyed (txid, ix), with a
  `spent_by` field that is null while UNSPENT (a UTXO) and the spending txid once
  consumed. We spend TXOs, not txs: an output is the entity with a create→spend
  lifecycle, so it's the row. The UTXO set is the VIEW `WHERE spent_by IS NULL`.

  Headline (the trap Ramsay set): block 16 spends block 3's output. Processing block 3
  creates its TXO (unspent); processing block 16 sets that TXO's spent_by to block 16's
  txid and creates block 16's own outputs (unspent). Resolution by (txid, ix) is a
  primary-key lookup — no scanning a chain for a hash.
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

  defp txid(n) do
    {:ok, [tx]} = Tx.txs_in(fixture(n))
    tx.txid
  end

  test "processing a block stores its outputs as unspent TXOs, resolvable by (txid, ix)" do
    :ok = ChainStore.process_block(fixture(3))

    t3 = txid(3)
    assert %{spent_by: nil, value: v} = ChainStore.txo(t3, 0)
    assert v > 0
    # A non-existent output resolves to nil (not an error).
    assert ChainStore.txo(t3, 99) == nil
  end

  test "the headline: block 16 spends block 3's output 0; both sets of TXOs are correct" do
    :ok = ChainStore.process_block(fixture(3))
    t3 = txid(3)
    assert %{spent_by: nil} = ChainStore.txo(t3, 0), "block 3's output starts unspent"

    :ok = ChainStore.process_block(fixture(16))
    t16 = txid(16)

    # Block 3's output 0 is now SPENT, by block 16's tx.
    assert %{spent_by: ^t16} = ChainStore.txo(t3, 0), "block 16 must mark block 3's output spent"

    # Block 16's own 4 outputs landed UNSPENT (new UTXOs).
    for ix <- 0..3, do: assert %{spent_by: nil} = ChainStore.txo(t16, ix)
    assert ChainStore.txo(t16, 4) == nil, "block 16 created exactly 4 outputs"
  end

  test "the UTXO set (unspent only) excludes spent outputs" do
    :ok = ChainStore.process_block(fixture(3))
    :ok = ChainStore.process_block(fixture(16))

    t3 = txid(3)
    t16 = txid(16)
    unspent = ChainStore.unspent_txos() |> MapSet.new(fn o -> {o.txid, o.ix} end)

    refute MapSet.member?(unspent, {t3, 0}), "spent output is NOT in the UTXO set"
    assert MapSet.member?(unspent, {t16, 0}), "block 16's fresh output IS in the UTXO set"
  end

  test "resolving an input whose source block isn't processed yet → unresolved (nil), not error" do
    # Process ONLY block 16. Its input references block 3's txid, which we haven't seen.
    :ok = ChainStore.process_block(fixture(16))
    t3 = txid(3)

    # The spent output simply isn't in our index yet — verdict-free, like an orphan
    # header. No crash; resolution returns nil.
    assert ChainStore.txo(t3, 0) == nil
    # And block 16's own outputs are still recorded (decoding/creating doesn't depend on
    # the input being resolvable).
    t16 = txid(16)
    assert %{spent_by: nil} = ChainStore.txo(t16, 0)
  end
end
