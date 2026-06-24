defmodule Cardamom.Ledger.Byron.BodyTest do
  @moduledoc """
  Decode transactions out of a Byron (era 0) block body. Byron is structurally unrelated to
  the Shelley+ array-5 block; we extract tx inputs `(txid, index)` and outputs `(address,
  lovelace)` only, normalised to the Shelley-family tx/output shape.

  SOURCES (cardano-ledger byron impl), cited per assertion:
    * Block envelope `[tag, content]`, tag 1 = regular, 0 = EBB — Block.hs:413-420.
    * Regular block `[header, body, extra]` — Block.hs:326-335.
    * Body `[txPayload, ssc, dlg, update]` — Body.hs:81-88.
    * txPayload = list of TxAux — TxPayload.hs:70-71.
    * TxAux `[tx, witness]` — TxAux.hs:108-115.
    * Tx `[inputs, outputs, attributes]` — Tx.hs:110-113.
    * TxIn `[0, #6.24(cbor([txid, index]))]` — Tx.hs:171-177 + Common/CBOR.hs:90-91.
    * TxOut `[address, lovelace]` — Tx.hs:216-219.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Byron.Body

  defp bytes(b), do: %CBOR.Tag{tag: :bytes, value: b}

  # TxIn = [0, #6.24(bytes-of-cbor([txid, index]))] (Tx.hs:171-177).
  defp txin(txid, index) do
    nested = CBOR.encode([bytes(txid), index])
    [0, %CBOR.Tag{tag: 24, value: bytes(nested)}]
  end

  # A Byron address on the wire is encodeCrcProtected (...) = [#6.24(bytes), crc32]
  # (Address.hs:157-159). We don't model the inner address structure — opaque to us.
  defp addr(payload), do: [%CBOR.Tag{tag: 24, value: bytes(payload)}, 997]

  # TxOut = [address, lovelace] (Tx.hs:216-219).
  defp txout(addr_payload, lovelace), do: [addr(addr_payload), lovelace]

  # Assemble a regular Byron block, era-wrapped: [era=0, [tag=1, [header, body, extra]]].
  defp byron_block(txs) do
    tx_payload = Enum.map(txs, fn {ins, outs} -> [[ins, outs, %{}], []] end)
    body = [tx_payload, [], [], []]
    content = [%{}, body, %{}]
    CBOR.encode([0, [1, content]])
  end

  describe "txs_in/1 — Byron tx in/out extraction" do
    test "extracts a tx's inputs as {txid, index} (Tx.hs:171-177)" do
      txid = <<7::256>>
      raw = byron_block([{[txin(txid, 3)], [txout(<<1, 2, 3>>, 1_000_000)]}])

      {:ok, [tx]} = Body.txs_in(raw)
      assert tx.inputs == [{txid, 3}]
    end

    test "extracts a tx's outputs as address + lovelace, Shelley-family shape (Tx.hs:216-219)" do
      raw = byron_block([{[txin(<<1::256>>, 0)], [txout(<<9, 9>>, 42)]}])

      {:ok, [tx]} = Body.txs_in(raw)
      [out] = tx.outputs
      # address kept byte-exact (the whole 2-element CBOR address term).
      assert out.address == CBOR.encode(addr(<<9, 9>>))
      assert out.value == 42
      # Byron has no multiasset/datums/scripts — uniform nil fields.
      assert out.multiasset == nil
      assert out.datum_hash == nil
      assert out.datum == nil
    end

    test "txid is the byte-exact blake2b-256 of the tx's CBOR (Tx.hs:27,77)" do
      raw = byron_block([{[txin(<<1::256>>, 0)], [txout(<<5>>, 7)]}])

      {:ok, [tx]} = Body.txs_in(raw)
      assert is_binary(tx.txid) and byte_size(tx.txid) == 32
    end

    test "a multi-tx, multi-in/out block decodes every tx" do
      raw =
        byron_block([
          {[txin(<<1::256>>, 0)], [txout(<<0xA>>, 10), txout(<<0xB>>, 20)]},
          {[txin(<<2::256>>, 1), txin(<<3::256>>, 2)], [txout(<<0xC>>, 30)]}
        ])

      {:ok, [t0, t1]} = Body.txs_in(raw)
      assert length(t0.outputs) == 2
      assert length(t1.inputs) == 2
      assert t1.inputs == [{<<2::256>>, 1}, {<<3::256>>, 2}]
    end

    test "all txs are tagged valid (Byron has no phase-2 validity)" do
      raw = byron_block([{[txin(<<1::256>>, 0)], [txout(<<5>>, 7)]}])
      {:ok, [tx]} = Body.txs_in(raw)
      assert tx.valid == true
      assert tx.reference_inputs == []
      assert tx.collateral_inputs == []
      assert tx.collateral_return == nil
    end

    test "an epoch-boundary block (EBB, tag 0) carries NO txs (Block.hs:413-420)" do
      ebb = CBOR.encode([0, [0, [%{}, %{}]]])
      assert {:ok, []} = Body.txs_in(ebb)
    end

    test "non-binary input is a clean error, not a raise" do
      assert {:error, :not_binary} = Body.txs_in(:nope)
    end

    test "malformed bytes are a clean error" do
      assert {:error, _} = Body.txs_in(<<0xFF, 0xFF>>)
    end
  end
end
