defmodule Cardamom.Store.MempoolCascadeTest do
  @moduledoc """
  The block → mempool cascade — the piece that makes a running mempool. When a block is
  processed, any input it spends invalidates the PENDING txs that depended on that UTxO:

    * a pending tx that SPENDS the same input → :inputs_spent (out-competed; not at fault).
    * a pending tx that REFERENCES (Ξ) the input → also dies (a spent refInput can't be
      read — Agda: refInputs ⊆ dom utxo).
    * a pending tx that confirmed IN the block → :in_block (promoted to the chain).
    * an unaffected pending tx → survives.

  Driven by the mempool_tx_inputs edge index (find-pending-by-input). Eviction is
  idempotent + monotone, so the cascade is order-independent (fully-parallel-safe).
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Conway.Tx

  defp bytes(b), do: %CBOR.Tag{tag: :bytes, value: b}

  # A pending tx body: spends `ins` (list of {txid,ix}), references `refs`, outputs one.
  defp pending(ins, refs \\ []) do
    body = %{
      0 => Enum.map(ins, fn {t, i} -> [bytes(t), i] end),
      1 => [[bytes(<<0xAA>>), 1_000_000]]
    }

    body = if refs == [], do: body, else: Map.put(body, 18, Enum.map(refs, fn {t, i} -> [bytes(t), i] end))
    {:ok, tx} = Tx.decode_tx(CBOR.encode(body))
    :ok = ChainStore.put_mempool_tx(tx)
    tx.txid
  end

  # A block that spends `ins` in one valid tx (creates one output).
  defp block_spending(ins) do
    body = %{0 => Enum.map(ins, fn {t, i} -> [bytes(t), i] end), 1 => [[bytes(<<0xBB>>), 5]]}
    inner = <<0x85>> <> CBOR.encode(%{}) <> CBOR.encode([body]) <> CBOR.encode([]) <> CBOR.encode([]) <> CBOR.encode([])
    <<0x82>> <> CBOR.encode(4) <> inner
  end

  test "edges are recorded when a pending tx is added" do
    txid = pending([{<<1::256>>, 0}], [{<<2::256>>, 0}])

    # mempool_spenders_of returns the SPENDER TXIDS that depend on an input (any kind —
    # spend OR reference; both make the input a dependency the cascade must invalidate).
    spenders = ChainStore.mempool_spenders_of(<<1::256>>, 0)
    refreaders = ChainStore.mempool_spenders_of(<<2::256>>, 0)

    assert txid in spenders, "the spend edge is recorded"
    assert txid in refreaders, "the reference edge is recorded too (a spent refInput invalidates the reader)"
  end

  test "a block spending a pending tx's input evicts it as :inputs_spent" do
    doomed = pending([{<<1::256>>, 0}])
    survivor = pending([{<<9::256>>, 0}])

    # A block spends UTxO <<1>>#0 (the input `doomed` wanted). It is now out-competed.
    _ = ChainStore.process_block(block_spending([{<<1::256>>, 0}]))

    assert ChainStore.mempool_txo(doomed, 0) == nil, "the out-competed tx leaves the mempool"
    assert [%{reason: "inputs_spent"}] = ChainStore.mempool_graveyard(doomed) |> Enum.filter(&(&1.ix == 0))

    # The unaffected pending tx survives.
    assert %{} = ChainStore.mempool_txo(survivor, 0), "an unaffected pending tx survives"
  end

  test "a block spending a REFERENCE input also evicts the reader" do
    reader = pending([{<<3::256>>, 0}], [{<<4::256>>, 0}])

    # The block spends <<4>>#0 — a UTxO `reader` only REFERENCES. A spent refInput can't
    # be read, so the reader is invalidated too.
    _ = ChainStore.process_block(block_spending([{<<4::256>>, 0}]))

    assert ChainStore.mempool_txo(reader, 0) == nil, "a reader whose refInput was spent is evicted"
  end

  test "a pending tx that CONFIRMS in the block is promoted :in_block" do
    # Build a pending tx, then a block that contains THAT SAME tx (it confirmed).
    body = %{0 => [[bytes(<<5::256>>), 0]], 1 => [[bytes(<<0xCC>>), 7]]}
    {:ok, tx} = Tx.decode_tx(CBOR.encode(body))
    :ok = ChainStore.put_mempool_tx(tx)

    inner = <<0x85>> <> CBOR.encode(%{}) <> CBOR.encode([body]) <> CBOR.encode([]) <> CBOR.encode([]) <> CBOR.encode([])
    block = <<0x82>> <> CBOR.encode(4) <> inner
    _ = ChainStore.process_block(block)

    assert ChainStore.mempool_txo(tx.txid, 0) == nil, "confirmed tx leaves the live mempool"
    assert [%{reason: "in_block"}] = ChainStore.mempool_graveyard(tx.txid) |> Enum.filter(&(&1.ix == 0))
  end

  test "the cascade is idempotent: re-processing the same block doesn't error" do
    doomed = pending([{<<1::256>>, 0}])
    block = block_spending([{<<1::256>>, 0}])
    _ = ChainStore.process_block(block)
    _ = ChainStore.process_block(block)
    assert ChainStore.mempool_txo(doomed, 0) == nil
  end
end
