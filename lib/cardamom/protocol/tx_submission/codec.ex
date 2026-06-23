defmodule Cardamom.Protocol.TxSubmission.Codec do
  @moduledoc """
  TxSubmission2 mini-protocol (4) codec. Grammar from the authoritative CDDL
  (ouroboros-network .../cddl/specs/tx-submission2.cddl):

      msgInit         = [6]
      msgRequestTxIds = [0, tsBlocking, txCount, txCount]   ; blocking, ack, req
      msgReplyTxIds   = [1, [ *[txId, txSize] ] ]
      msgRequestTxs   = [2, [ *txId ] ]
      msgReplyTxs     = [3, [ *tx ] ]
      tsMsgDone       = [4]

  The id/tx lists MUST be INDEFINITE-length (CBOR 0x9f .. 0xff) — the reference codec
  only accepts that encoding, so we emit them by hand rather than via CBOR.encode (which
  produces definite-length arrays). txId is a 32-byte hash; tx is opaque bytes kept inert
  at this layer (Harvard boundary — the body is decoded by the ledger, not here). Strict:
  decode never raises.
  """

  @type txid :: binary()
  @type message ::
          :init
          | {:request_tx_ids, boolean(), non_neg_integer(), non_neg_integer()}
          | {:reply_tx_ids, [{txid(), non_neg_integer()}]}
          | {:request_txs, [txid()]}
          | {:reply_txs, [binary()]}
          | :done

  @break 0xFF
  @indef_array 0x9F

  # ---- encode ----

  @spec encode(message()) :: binary()
  def encode(:init), do: CBOR.encode([6])
  def encode(:done), do: CBOR.encode([4])

  def encode({:request_tx_ids, blocking, ack, req})
      when is_boolean(blocking) and is_integer(ack) and is_integer(req),
      do: CBOR.encode([0, blocking, ack, req])

  def encode({:reply_tx_ids, ids}) when is_list(ids) do
    # [1, indef[ [txid, size] ... ]]
    items = Enum.map(ids, fn {txid, size} -> CBOR.encode([bytes(txid), size]) end)
    array_head(1) <> indef(items)
  end

  def encode({:request_txs, ids}) when is_list(ids) do
    items = Enum.map(ids, fn txid -> CBOR.encode(bytes(txid)) end)
    array_head(2) <> indef(items)
  end

  def encode({:reply_txs, txs}) when is_list(txs) do
    items = Enum.map(txs, fn tx -> CBOR.encode(bytes(tx)) end)
    array_head(3) <> indef(items)
  end

  # CBOR array(2) head (0x82) + the tag integer — the prefix of a `[tag, <indef list>]`.
  defp array_head(tag), do: <<0x82>> <> CBOR.encode(tag)

  # Wrap the already-encoded items in an indefinite-length array (0x9f .. 0xff).
  defp indef(item_binaries), do: <<@indef_array>> <> IO.iodata_to_binary(item_binaries) <> <<@break>>

  defp bytes(b), do: %CBOR.Tag{tag: :bytes, value: b}

  # ---- decode (strict; never raises) ----

  @spec decode(binary()) :: {:ok, message(), binary()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    case CBOR.decode(bytes) do
      {:ok, term, rest} -> with {:ok, msg} <- from_term(term), do: {:ok, msg, rest}
      {:error, e} -> {:error, {:cbor, e}}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  defp from_term([6]), do: {:ok, :init}
  defp from_term([4]), do: {:ok, :done}

  defp from_term([0, blocking, ack, req])
       when is_boolean(blocking) and is_integer(ack) and is_integer(req),
       do: {:ok, {:request_tx_ids, blocking, ack, req}}

  defp from_term([1, ids]) when is_list(ids) do
    {:ok, {:reply_tx_ids, Enum.map(ids, fn [txid, size] -> {unbytes(txid), size} end)}}
  end

  defp from_term([2, ids]) when is_list(ids),
    do: {:ok, {:request_txs, Enum.map(ids, &unbytes/1)}}

  defp from_term([3, txs]) when is_list(txs),
    do: {:ok, {:reply_txs, Enum.map(txs, &unbytes/1)}}

  defp from_term(other), do: {:error, {:unknown_tx_submission_message, other}}

  defp unbytes(%CBOR.Tag{tag: :bytes, value: b}), do: b
  defp unbytes(b) when is_binary(b), do: b
end
