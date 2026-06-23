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

  # Build a synthetic block from tx-body terms + invalid-tx indices (era-wrapped, the
  # [era, [hdr, bodies, wits, aux, invalid]] shape txs_in walks).
  defp block_with(tx_body_terms, invalid_ixs) do
    bodies = CBOR.encode(tx_body_terms)
    empty = CBOR.encode([])
    inner = <<0x85>> <> CBOR.encode(%{}) <> bodies <> empty <> empty <> CBOR.encode(invalid_ixs)
    <<0x82>> <> CBOR.encode(4) <> inner
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

  test "a valid spend records spent_how :tx_input" do
    :ok = ChainStore.process_block(fixture(3))
    :ok = ChainStore.process_block(fixture(16))
    assert %{spent_how: "tx_input"} = ChainStore.txo(txid(3), 0)
  end

  # The phase-2-fail path (Agda Utxo.lagda.md ~503): an INVALID tx consumes its COLLATERAL,
  # NOT its normal inputs/outputs. Synthetic block — seed a collateral UTXO + a normal-
  # input UTXO, then an invalid tx that would spend the normal input and create an output,
  # but (being invalid) actually only burns its collateral.
  test "an invalid (phase-2-fail) tx consumes collateral, not its normal inputs/outputs" do
    bytes = fn b -> %CBOR.Tag{tag: :bytes, value: b} end

    # Pre-existing UTXOs the tx will name: a normal input and a collateral input.
    normal_in = <<1::256>>
    collat_in = <<2::256>>
    {:ok, _} = Cardamom.Store.Repo.insert(%Cardamom.Store.Txo{txid: normal_in, ix: 0, value: 5_000_000})
    {:ok, _} = Cardamom.Store.Repo.insert(%Cardamom.Store.Txo{txid: collat_in, ix: 0, value: 2_000_000})

    # An INVALID tx: normal input = normal_in#0, an output, collateral = collat_in#0.
    invalid_tx = %{
      0 => [[bytes.(normal_in), 0]],
      1 => [[bytes.(<<0xBB>>), 4_000_000]],
      13 => [[bytes.(collat_in), 0]]
    }

    block = block_with([invalid_tx], [0])
    {:ok, [decoded]} = Tx.txs_in(block)
    spender = decoded.txid
    :ok = ChainStore.process_block(block)

    # Collateral WAS consumed, spent_how :collateral.
    assert %{spent_by: ^spender, spent_how: "collateral"} = ChainStore.txo(collat_in, 0)
    # The normal input was NOT spent (invalid txs don't spend their normal inputs).
    assert %{spent_by: nil} = ChainStore.txo(normal_in, 0)
    # The normal output was NOT created.
    assert ChainStore.txo(spender, 0) == nil
  end

  test "an output with an INLINE DATUM is stored with the datum encoded" do
    bytes = fn b -> %CBOR.Tag{tag: :bytes, value: b} end
    inline = [1, 2, 3]
    # Map output {0: addr, 1: value, 2: [1, inline_datum]}.
    tx = %{0 => [[bytes.(<<1::256>>), 0]], 1 => [%{0 => bytes.(<<9>>), 1 => 42, 2 => [1, inline]}]}
    block = block_with([tx], [])
    {:ok, [decoded]} = Tx.txs_in(block)
    :ok = ChainStore.process_block(block)

    row = ChainStore.txo(decoded.txid, 0)
    assert row != nil
    assert row.datum != nil, "an inline datum is persisted (encode_datum path)"
    # And it round-trips back to the original term.
    assert {:ok, ^inline, ""} = CBOR.decode(row.datum)
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
