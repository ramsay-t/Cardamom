defmodule Cardamom.Protocol.TxSubmission.CodecTest do
  @moduledoc """
  TxSubmission2 (proto 4) codec, grammar from the authoritative CDDL
  (ouroboros-network .../cddl/specs/tx-submission2.cddl):

      msgInit         = [6]
      msgRequestTxIds = [0, tsBlocking, txCount, txCount]   ; blocking, ack, req
      msgReplyTxIds   = [1, [ *[txId, txSize] ] ]
      msgRequestTxs   = [2, [ *txId ] ]
      msgReplyTxs     = [3, [ *tx ] ]
      tsMsgDone       = [4]

  CRITICAL: the codec only accepts INDEFINITE-length lists (CBOR 0x9f .. 0xff) for the
  id/tx lists — a definite-length array is a different encoding the reference rejects.
  txId is a 32-byte hash; tx is opaque bytes (we keep it inert at the codec layer).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Protocol.TxSubmission.Codec

  test "init / done / request_txs round-trip" do
    assert {:ok, :init, ""} = Codec.decode(Codec.encode(:init))
    assert {:ok, :done, ""} = Codec.decode(Codec.encode(:done))
  end

  test "request_tx_ids carries blocking flag + ack and req counts" do
    msg = {:request_tx_ids, true, 3, 10}
    assert {:ok, {:request_tx_ids, true, 3, 10}, ""} = Codec.decode(Codec.encode(msg))

    msg2 = {:request_tx_ids, false, 0, 5}
    assert {:ok, {:request_tx_ids, false, 0, 5}, ""} = Codec.decode(Codec.encode(msg2))
  end

  test "reply_tx_ids carries [{txid, size}] pairs" do
    ids = [{<<1::256>>, 200}, {<<2::256>>, 350}]
    assert {:ok, {:reply_tx_ids, ^ids}, ""} = Codec.decode(Codec.encode({:reply_tx_ids, ids}))
  end

  test "request_txs carries a list of txids" do
    ids = [<<1::256>>, <<2::256>>]
    assert {:ok, {:request_txs, ^ids}, ""} = Codec.decode(Codec.encode({:request_txs, ids}))
  end

  test "reply_txs carries opaque tx bodies (kept inert)" do
    txs = [<<0xAA, 0xBB>>, <<0xCC>>]
    assert {:ok, {:reply_txs, ^txs}, ""} = Codec.decode(Codec.encode({:reply_txs, txs}))
  end

  test "the id/tx lists are encoded INDEFINITE-length (0x9f .. 0xff)" do
    enc = Codec.encode({:request_txs, [<<1::256>>]})
    # [2, <indef list>] — after the [2,...] array head, the list must start 0x9f.
    assert :binary.match(enc, <<0x9F>>) != :nomatch, "must use an indefinite-length list"
    assert :binary.last(enc) == 0xFF, "indefinite list ends with the 0xFF break"
  end

  test "empty reply lists round-trip" do
    assert {:ok, {:reply_tx_ids, []}, ""} = Codec.decode(Codec.encode({:reply_tx_ids, []}))
    assert {:ok, {:reply_txs, []}, ""} = Codec.decode(Codec.encode({:reply_txs, []}))
  end

  test "garbage / unknown tag is a clean error, never a raise" do
    assert {:error, _} = Codec.decode(CBOR.encode([99]))
    assert {:error, _} = Codec.decode(<<0xFF, 0xFF>>)
  end
end
