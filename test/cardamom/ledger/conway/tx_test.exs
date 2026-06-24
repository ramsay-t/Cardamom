defmodule Cardamom.Ledger.Conway.TxTest do
  @moduledoc """
  Decoding Conway transactions out of a real block, against committed fixtures of two
  early Preview blocks that actually contain txs (block 3 and block 16 — the genesis
  stake-pool registration). The txid is the blake2b-256 of the tx body's ORIGINAL CBOR
  bytes (byte-exact, not re-encoded) — this is what a spending tx's input references, so
  it MUST match exactly. Block 16 spends block 3's output (verified: same txid), which is
  the headline case for UTXO resolution.

  Conway transaction_body keys we decode (CDDL, ouroboros/cardano-ledger):
    0 = inputs   (set of [tx_hash, index])
    1 = outputs  (array of TxOut)
    2 = fee
    (others — certs/mint/validity/witnesses — not extracted; they live in the block raw)
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Conway.Tx

  defp fixture(n) do
    Path.join([__DIR__, "..", "..", "..", "fixtures", "blocks", "block-#{n}.hex"])
    |> File.read!()
    |> String.trim()
    |> Base.decode16!(case: :lower)
  end

  # The known txid of block 3's single tx (computed byte-exact, cross-checked live).
  @block3_txid "a8fa4293645facb2a0332f4dfc442dff3fc9ca021c95ee908df5d9605e3825be"

  describe "txs_in/1 — decode the transactions of a block" do
    test "block 3 has one tx with the expected (byte-exact) txid" do
      {:ok, [tx]} = Tx.txs_in(fixture(3))
      assert Base.encode16(tx.txid, case: :lower) == @block3_txid
    end

    test "block 3's tx has 1 input and 1 output (the simple genesis spend)" do
      {:ok, [tx]} = Tx.txs_in(fixture(3))
      assert length(tx.inputs) == 1
      assert length(tx.outputs) == 1
    end

    test "block 16's tx has 1 input and 4 outputs (three 100M-ADA + change)" do
      {:ok, [tx]} = Tx.txs_in(fixture(16))
      assert length(tx.inputs) == 1
      assert length(tx.outputs) == 4
      # Three genesis delegation outputs of exactly 100M ADA (100_000_000_000_000 lovelace).
      values = Enum.map(tx.outputs, & &1.value)
      assert Enum.count(values, &(&1 == 100_000_000_000_000)) == 3
    end

    test "outputs carry an address and a (non-zero) value" do
      {:ok, [tx]} = Tx.txs_in(fixture(3))
      first = hd(tx.outputs)
      assert is_binary(first.address) and byte_size(first.address) > 0
      assert is_integer(first.value) and first.value > 0
    end

    test "an input is a {txid, index} reference" do
      {:ok, [tx]} = Tx.txs_in(fixture(3))
      [{in_txid, ix}] = tx.inputs
      assert is_binary(in_txid) and byte_size(in_txid) == 32
      assert is_integer(ix) and ix >= 0
    end
  end

  # Real blocks 3/16 only have legacy-array outputs and simple values. These synthetic
  # tx bodies hit the output SHAPES those blocks don't: post-Babbage map outputs, datum
  # hashes, inline datums, multi-asset values — the decoder branches a richer block would
  # exercise live. We build a one-tx block of [era, [hdr, [tx_body], wits, aux, invalid]]
  # so txs_in/1 walks the real path. (header/wits/aux/invalid are placeholders — txs_in
  # only reads tx_bodies.)
  describe "output shapes blocks 3/16 don't contain (synthetic tx bodies)" do
    defp block_of(tx_body_term) do
      bodies = CBOR.encode([tx_body_term])
      hdr = CBOR.encode(%{})
      empties = CBOR.encode([])
      inner = <<0x85>> <> hdr <> bodies <> empties <> empties <> empties
      # [era, inner] — era-wrapped (the 0x82 path).
      CBOR.encode(4) |> then(fn era -> <<0x82>> <> era <> inner end)
    end

    defp bytes(b), do: %CBOR.Tag{tag: :bytes, value: b}

    test "post-Babbage MAP output with a DATUM HASH decodes" do
      datum_h = :crypto.strong_rand_bytes(32)
      # tx_body {0: inputs, 1: [ {0: addr, 1: value, 2: [0, datum_hash]} ]}
      body = %{
        0 => [[bytes(:crypto.strong_rand_bytes(32)), 0]],
        1 => [%{0 => bytes(<<1, 2, 3>>), 1 => 5_000_000, 2 => [0, bytes(datum_h)]}]
      }

      {:ok, [tx]} = Tx.txs_in(block_of(body))
      [out] = tx.outputs
      assert out.address == <<1, 2, 3>>
      assert out.value == 5_000_000
      assert out.datum_hash == datum_h
      assert out.datum == nil
    end

    test "map output with an INLINE DATUM decodes" do
      inline = [1, 2, 3]
      body = %{
        0 => [[bytes(:crypto.strong_rand_bytes(32)), 0]],
        1 => [%{0 => bytes(<<9>>), 1 => 42, 2 => [1, inline]}]
      }

      {:ok, [tx]} = Tx.txs_in(block_of(body))
      [out] = tx.outputs
      assert out.datum == inline
      assert out.datum_hash == nil
    end

    # value (conway.cddl:174 `coin/ [coin, multiasset<positive_coin>]`, multiasset:178
    # `{* policy_id => {+ asset_name => a0}}`): keep BOTH the lovelace coin (back-compat) AND
    # the full token bundle. policy_id = script_hash (28B), asset_name = bytes .size 0..32.
    test "MULTI-ASSET value [coin, assets] keeps the lovelace coin AND the token bundle" do
      policy = :crypto.strong_rand_bytes(28)
      asset = "TOKEN"

      body = %{
        0 => [[bytes(:crypto.strong_rand_bytes(32)), 0]],
        1 => [%{0 => bytes(<<7>>), 1 => [1_234, %{bytes(policy) => %{bytes(asset) => 99}}]}]
      }

      {:ok, [tx]} = Tx.txs_in(block_of(body))
      out = hd(tx.outputs)
      assert out.value == 1_234, "lovelace coin preserved for back-compat"
      # multiasset unwrapped to raw binaries: %{policy_id => %{asset_name => amount}}.
      assert out.multiasset == %{policy => %{asset => 99}}
    end

    # shelley.cddl `value = coin` (no multiasset); any ADA-only output is a bare uint.
    test "a bare-coin (ADA-only / Shelley) value has nil multiasset" do
      body = %{
        0 => [[bytes(:crypto.strong_rand_bytes(32)), 0]],
        1 => [%{0 => bytes(<<7>>), 1 => 5_000_000}]
      }

      {:ok, [tx]} = Tx.txs_in(block_of(body))
      out = hd(tx.outputs)
      assert out.value == 5_000_000
      assert out.multiasset == nil
    end

    test "a legacy-array output's multiasset is also preserved" do
      policy = :crypto.strong_rand_bytes(28)

      body = %{
        0 => [[bytes(:crypto.strong_rand_bytes(32)), 0]],
        1 => [[bytes(<<7>>), [42, %{bytes(policy) => %{bytes(<<>>) => 1}}]]]
      }

      {:ok, [tx]} = Tx.txs_in(block_of(body))
      out = hd(tx.outputs)
      assert out.value == 42
      # asset_name may be empty (size 0..32) — the empty-name token still kept.
      assert out.multiasset == %{policy => %{<<>> => 1}}
    end

    test "legacy-array output WITH a datum hash (3rd element) decodes" do
      datum_h = :crypto.strong_rand_bytes(32)
      body = %{
        0 => [[bytes(:crypto.strong_rand_bytes(32)), 0]],
        1 => [[bytes(<<5>>), 99, bytes(datum_h)]]
      }

      {:ok, [tx]} = Tx.txs_in(block_of(body))
      assert hd(tx.outputs).datum_hash == datum_h
    end

    test "a tx with no inputs/outputs keys yields empty lists, not a crash" do
      {:ok, [tx]} = Tx.txs_in(block_of(%{2 => 100}))
      assert tx.inputs == []
      assert tx.outputs == []
    end
  end

  # invalid_transactions (5th block segment) + collateral (tx body key 13) + collateral
  # return (key 16) — the phase-2-fail path. Per the Agda spec (Utxo.lagda.md): a tx
  # listed as invalid consumes its COLLATERAL, not its txIns/txOuts.
  describe "valid/invalid tagging + collateral (phase-2 fail)" do
    # Build a block from several tx-body terms and a list of invalid indices.
    defp block_with(tx_body_terms, invalid_ixs) do
      bodies = CBOR.encode(tx_body_terms)
      hdr = CBOR.encode(%{})
      empty = CBOR.encode([])
      invalid = CBOR.encode(invalid_ixs)
      inner = <<0x85>> <> hdr <> bodies <> empty <> empty <> invalid
      <<0x82>> <> CBOR.encode(4) <> inner
    end

    defp bytes2(b), do: %CBOR.Tag{tag: :bytes, value: b}

    test "txs are tagged valid/invalid from the invalid_transactions list" do
      tx0 = %{0 => [[bytes2(<<1::256>>), 0]], 1 => [[bytes2(<<0xAA>>), 100]]}
      tx1 = %{0 => [[bytes2(<<2::256>>), 0]], 1 => [[bytes2(<<0xBB>>), 200]]}
      # tx at index 1 is invalid (phase-2 failed).
      {:ok, [t0, t1]} = Tx.txs_in(block_with([tx0, tx1], [1]))
      assert t0.valid == true
      assert t1.valid == false
    end

    test "an invalid tx exposes its collateral inputs (key 13) and collateral return (key 16)" do
      tx = %{
        0 => [[bytes2(<<1::256>>), 0]],
        1 => [[bytes2(<<0xAA>>), 100]],
        13 => [[bytes2(<<9::256>>), 0]],
        16 => [bytes2(<<0xCC>>), 50]
      }

      {:ok, [t]} = Tx.txs_in(block_with([tx], [0]))
      assert t.valid == false
      assert [{<<9::256>>, 0}] = t.collateral_inputs
      assert %{value: 50} = t.collateral_return
    end
  end

  describe "reference inputs (Ξ) + the txIns ∩ refInputs disjointness invariant" do
    defp bytes3(b), do: %CBOR.Tag{tag: :bytes, value: b}

    test "reference_inputs (key 18) are decoded as Ξ (read-only), separate from inputs" do
      tx = %{
        0 => [[bytes3(<<1::256>>), 0]],
        1 => [[bytes3(<<0xAA>>), 1]],
        18 => [[bytes3(<<7::256>>), 0], [bytes3(<<8::256>>), 1]]
      }

      {:ok, [t]} = Tx.txs_in(block_with([tx], []))
      assert t.inputs == [{<<1::256>>, 0}]
      assert t.reference_inputs == [{<<7::256>>, 0}, {<<8::256>>, 1}]
    end

    test "a tx with no reference_inputs has an empty Ξ" do
      {:ok, [t]} = Tx.txs_in(block_with([%{0 => [[bytes3(<<1::256>>), 0]], 1 => []}], []))
      assert t.reference_inputs == []
    end
  end

  describe "block envelope + array-size shapes" do
    test "a BARE array(5) block (no era wrapper, 0x85) decodes" do
      # Some shapes arrive un-era-wrapped: just the [hdr, bodies, wits, aux, invalid].
      tx = %{0 => [[bytes3(<<1::256>>), 0]], 1 => [[bytes3(<<0xAA>>), 5]]}
      bare = <<0x85>> <> CBOR.encode(%{}) <> CBOR.encode([tx]) <> CBOR.encode([]) <> CBOR.encode([]) <> CBOR.encode([])
      assert {:ok, [t]} = Tx.txs_in(bare)
      assert t.outputs != []
    end

    test "a block with >23 txs uses the 0x98 array-count header and still splits per-tx" do
      # 24 txs forces CBOR's 1-byte-count array header (0x98 0x18) — the split_array path
      # that small blocks never exercise.
      txs = for i <- 0..23, do: %{0 => [[bytes3(<<i::256>>), 0]], 1 => [[bytes3(<<i>>), 1]]}
      {:ok, decoded} = Tx.txs_in(block_with(txs, []))
      assert length(decoded) == 24, "all 24 txs split out individually"
      assert Enum.all?(decoded, &(&1.txid != nil))
    end
  end

  describe "strictness / malformed input" do
    test "non-binary input is a clean error" do
      assert {:error, :not_binary} = Tx.txs_in(:not_bytes)
    end

    test "decode_tx/1 rejects a non-binary cleanly" do
      assert {:error, :not_binary} = Tx.decode_tx(:nope)
    end

    test "bytes that aren't a block envelope are a clean error, not a raise" do
      assert {:error, _} = Tx.txs_in(<<0xFF, 0xFF, 0xFF>>)
    end
  end

  describe "the headline: block 16 spends block 3's output" do
    test "block 16's tx input references block 3's txid (resolution target)" do
      {:ok, [tx16]} = Tx.txs_in(fixture(16))
      {:ok, [tx3]} = Tx.txs_in(fixture(3))

      [{spent_txid, spent_ix}] = tx16.inputs
      # Block 16 spends block 3's tx, output 0 — the input points AT tx3's txid.
      assert spent_txid == tx3.txid, "block 16's input must reference block 3's txid"
      assert spent_ix == 0
    end

    test "block 16's tx decodes its own outputs (which become new TXOs)" do
      {:ok, [tx16]} = Tx.txs_in(fixture(16))
      assert tx16.outputs != []
      assert Enum.all?(tx16.outputs, &(is_binary(&1.address) and is_integer(&1.value)))
    end
  end
end
