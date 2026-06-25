defmodule Cardamom.GenesisTest do
  @moduledoc """
  Genesis-UTXO loading: seed the initial UTxO set (Shelley + Byron initial funds) that
  lives in the genesis ledger state, not in any block body — so chain spends of those
  UTXOs resolve. Derivations are the protocol's (cited per test), so this works for ANY
  Cardano network, not just Preview.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{ChainStore, Crypto, Genesis}

  # The real Preview byron-genesis (its nonAvvmBalances seed Preview's initial funds).
  @preview_byron "/Users/ramsay/GoogleDrive/IOHK/preview-config/byron-genesis.json"
  # Preview's single NON-ZERO nonAvvmBalances entry: 30B ADA. Its genesis UTXO is the
  # input live Preview block 3 spends (4843cf2e...:0). base58(addr) IS CBOR_encode(addr).
  @preview_nonzero_b58 "FHnt4NL7yPXvDWHa8bVs73UEUdJd64VxWXSFNqetECtYfTd9TtJguJ14Lu3feth"
  @preview_nonzero_coin 30_000_000_000_000_000
  @preview_nonzero_txid Base.decode16!(
                          "4843CF2E582B2F9CE37600E5AB4CC678991F988F8780FED05407F9537F7712BD"
                        )

  describe "Shelley derivation (Shelley/Genesis.hs:660 initialFundsPseudoTxIn)" do
    test "txid = blake2b_256(serialiseAddr(addr)) = blake2b_256(hex-decoded key), ix 0, value coin" do
      # serialiseAddr form is the hex-decoded initialFunds key; pseudoTxId hashes those bytes.
      addr_bytes = :crypto.strong_rand_bytes(57)
      hex_addr = Base.encode16(addr_bytes, case: :lower)
      coin = 1_000_000

      [{txid, ix, address, value}] = Genesis.derive_shelley(%{hex_addr => coin})

      assert txid == Crypto.blake2b_256(addr_bytes)
      assert ix == 0
      assert address == addr_bytes
      assert value == coin
    end
  end

  describe "Byron derivation (byron UTxO.hs:130 fromTxOut / serializeCborHash)" do
    test "base58-decoded key IS CBOR_encode(address) — starts 0x82/0x83" do
      cbor = Genesis.base58_decode!(@preview_nonzero_b58)
      assert <<first, _::binary>> = cbor
      assert first in [0x82, 0x83]
    end

    test "txid = blake2b_256(base58-decoded key), ix 0, with the 30B value" do
      [{txid, ix, address, value}] =
        Genesis.derive_byron(%{@preview_nonzero_b58 => Integer.to_string(@preview_nonzero_coin)})

      cbor = Genesis.base58_decode!(@preview_nonzero_b58)
      assert txid == Crypto.blake2b_256(cbor)
      assert ix == 0
      assert address == cbor
      assert value == @preview_nonzero_coin
      # And it derives to the very txid Preview block 3 spends.
      assert txid == @preview_nonzero_txid
    end
  end

  describe "base58_decode! (hand-rolled Bitcoin alphabet — no dep)" do
    test "leading '1' chars become leading zero bytes" do
      # Bitcoin base58: '1' is value 0; the standard preserves them as 0x00 prefix bytes.
      assert <<0, 0, rest::binary>> = Genesis.base58_decode!("11" <> "2")
      assert rest == :binary.encode_unsigned(1)
    end

    test "raises on an invalid character" do
      # '0', 'O', 'I', 'l' are NOT in the base58 alphabet.
      assert_raise ArgumentError, fn -> Genesis.base58_decode!("0") end
    end
  end

  describe "load/1 seeds genesis UTXOs into the txos table (via ChainStore)" do
    @tag :genesis_files
    test "seeding Preview's byron-genesis creates the 30B-ADA genesis UTXO" do
      if File.exists?(@preview_byron) do
        {:ok, count} = Genesis.load(byron: @preview_byron)
        # Preview has 8 nonAvvmBalances (incl. the zero ones); shelley nil → byron only.
        assert count == 8

        row = ChainStore.txo(@preview_nonzero_txid, 0)
        assert row != nil
        assert row.value == @preview_nonzero_coin
        assert row.spent_by == nil
        # created_txid is the genesis pseudo-txid itself (no producing tx).
        assert row.created_txid == @preview_nonzero_txid
      end
    end

    test "nil paths seed nothing" do
      assert {:ok, 0} = Genesis.load(shelley: nil, byron: nil)
    end

    test "re-seeding is idempotent — no duplicate rows, no error" do
      # A small synthetic byron-genesis written to a temp file (network-agnostic, no real file).
      b58 = @preview_nonzero_b58
      path = Path.join(System.tmp_dir!(), "byron_genesis_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(%{"nonAvvmBalances" => %{b58 => "12345"}, "avvmDistr" => %{}}))
      on_exit(fn -> File.rm(path) end)

      {:ok, 1} = Genesis.load(byron: path)
      {:ok, 1} = Genesis.load(byron: path)

      [{txid, _ix, _addr, _v}] = Genesis.derive_byron(%{b58 => "12345"})
      row = ChainStore.txo(txid, 0)
      assert row.value == 12_345

      # Exactly one row for that (txid, 0) — UPSERT, not a second insert.
      import Ecto.Query
      count = Repo.aggregate(from(t in Cardamom.Store.Txo, where: t.txid == ^txid), :count)
      assert count == 1
    end
  end
end
