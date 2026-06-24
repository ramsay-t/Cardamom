defmodule Cardamom.Ledger.BlockTest do
  @moduledoc """
  Era dispatch for block-body/tx decoding. The `[era, inner]` envelope's era tag is the
  HardFork CardanoEras index (0 Byron .. 7 Dijkstra). Byron (0) routes to
  `Cardamom.Ledger.Byron.Body`; the Shelley FAMILY (1-7) shares the array-5 block + a single
  decoder (`Cardamom.Ledger.Conway.Tx`). Unknown era → `{:error, {:unknown_era, tag}}`.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Block

  defp bytes(b), do: %CBOR.Tag{tag: :bytes, value: b}

  # A Shelley-family block: [era, [hdr, [tx_body], wits, aux, invalid]].
  defp shelley_family_block(era) do
    body = %{0 => [[bytes(<<1::256>>), 0]], 1 => [[bytes(<<0xAA>>), 100]]}
    inner = <<0x85>> <> CBOR.encode(%{}) <> CBOR.encode([body]) <>
              CBOR.encode([]) <> CBOR.encode([]) <> CBOR.encode([])
    <<0x82>> <> CBOR.encode(era) <> inner
  end

  # A minimal era-wrapped Byron regular block with one tx.
  defp byron_block do
    nested = CBOR.encode([bytes(<<7::256>>), 0])
    txin = [0, %CBOR.Tag{tag: 24, value: bytes(nested)}]
    addr = [%CBOR.Tag{tag: 24, value: bytes(<<1, 2, 3>>)}, 997]
    tx = [[txin], [[addr, 1_000_000]], %{}]
    body = [[[tx, []]], [], [], []]
    CBOR.encode([0, [1, [%{}, body, %{}]]])
  end

  describe "txs_in/2 — explicit era tag" do
    test "era 0 routes to the Byron decoder and extracts the tx" do
      {:ok, [tx]} = Block.txs_in(0, byron_block())
      assert tx.inputs == [{<<7::256>>, 0}]
      assert hd(tx.outputs).value == 1_000_000
    end

    for era <- 1..7 do
      test "era #{era} routes to the Shelley-family decoder" do
        {:ok, [tx]} = Block.txs_in(unquote(era), shelley_family_block(unquote(era)))
        assert tx.inputs == [{<<1::256>>, 0}]
        assert hd(tx.outputs).value == 100
      end
    end

    test "an unknown era is a strict error" do
      assert {:error, {:unknown_era, 8}} = Block.txs_in(8, shelley_family_block(8))
      assert {:error, {:unknown_era, 99}} = Block.txs_in(99, byron_block())
    end
  end

  describe "txs_in/1 — reads the era tag from the [era, inner] envelope" do
    test "era 0 envelope → Byron path" do
      {:ok, [tx]} = Block.txs_in(byron_block())
      assert tx.inputs == [{<<7::256>>, 0}]
    end

    test "era 6 (Conway) envelope → Shelley-family path" do
      {:ok, [tx]} = Block.txs_in(shelley_family_block(6))
      assert hd(tx.outputs).value == 100
    end

    test "a bare array-5 block (no era wrapper) defaults to the Shelley-family path" do
      body = %{0 => [[bytes(<<1::256>>), 0]], 1 => [[bytes(<<0xAA>>), 5]]}
      bare = <<0x85>> <> CBOR.encode(%{}) <> CBOR.encode([body]) <>
               CBOR.encode([]) <> CBOR.encode([]) <> CBOR.encode([])
      assert {:ok, [tx]} = Block.txs_in(bare)
      assert hd(tx.outputs).value == 5
    end

    test "non-binary input is a clean error" do
      assert {:error, :not_binary} = Block.txs_in(:nope)
    end
  end
end
