defmodule Cardamom.Ledger.Byron.Body do
  @moduledoc """
  Decode the transactions out of a **Byron** block body (era 0). Byron is structurally
  unrelated to the Shelley+ `[header, tx_bodies, witnesses, aux, invalid]` array-5; it has
  its own block/body shape. We extract ONLY what TXO tracking needs — tx inputs `(txid,
  index)` and outputs `(address, lovelace)` — normalised to the SAME tx/output map the
  Shelley-family decoder (`Cardamom.Ledger.Conway.Tx`) produces, so ChainStore stores both
  uniformly. Byron has no multiasset, no datums, no scripts, no phase-2 validity — those
  fields are nil/empty.

  SOURCES OF TRUTH (cardano-ledger byron impl):

    * Block envelope — `Block.hs`:
        - `decCBORABlockOrBoundary` (Block.hs:413-420): the block is `[Word tag, content]`
          (array-2); tag 0 = epoch-boundary block (EBB, NO txs), tag 1 = regular block.
        - `decCBORABlock` (Block.hs:326-335): a regular block is `[header, body,
          extra_body_data]` (array-3, "Block" enforceSize 3). We want element 1, the body.
        - On the network the whole thing is era-wrapped `[era=0, [tag, content]]` — same
          `[era, inner]` envelope the Shelley path uses.

    * Body — `Body.hs`:
        - `decCBOR (ABody ByteSpan)` (Body.hs:81-88): body = `[txPayload, sscPayload,
          dlgPayload, updatePayload]` (array-4, "Body" enforceSize 4). We want element 0.

    * TxPayload — `TxPayload.hs`:
        - `ATxPayload` (TxPayload.hs:43-46, 70-71): a LIST of `TxAux`. (`decCBOR = ATxPayload
          <$> decCBOR`, the list instance.)

    * TxAux — `TxAux.hs`:
        - `decCBOR (ATxAux ByteSpan)` (TxAux.hs:108-115): `[tx, witness]` (array-2, "TxAux"
          enforceSize 2). We want element 0, the tx; the witness is dropped.

    * Tx — `Tx.hs`:
        - `decCBOR Tx` (Tx.hs:110-113): `[inputs, outputs, attributes]` (array-3, "Tx"
          enforceSize 3). `txInputs` is a NonEmpty `TxIn`, `txOutputs` a NonEmpty `TxOut`.
        - The txid Byron uses is `serializeCborHash tx` = `blake2b_256` of the tx's CBOR
          (Tx.hs:27,77). We compute it byte-exactly off each tx's ORIGINAL bytes (carved,
          never re-encoded), matching the Shelley-family `txid` convention.

    * TxIn — `Tx.hs`:
        - `decCBOR TxIn` (Tx.hs:171-177): `[tag, knownCborDataItem]` (array-2). tag 0 =
          `TxInUtxo TxId Word16`. `decodeKnownCborDataItem` = `decodeNestedCbor` (Common/
          CBOR.hs:90-91), i.e. a CBOR #6.24 tag wrapping the bytes of `cbor([txid, index])`.
          So a TxIn on the wire is `[0, #6.24(bytes-of-cbor([txid(32B), index]))]`.

    * TxOut — `Tx.hs`:
        - `decCBOR TxOut` (Tx.hs:216-219): `[address, lovelace]` (array-2). `address` is a
          Byron `Address` = `encodeCrcProtected (root, attrs, type)` (Address.hs:157-159) =
          `[#6.24(bytes-of-cbor((root, attrs, type))), crc32]`. We keep the address as its
          byte-exact CBOR re-encoding (the whole 2-element address term) — downstream stores
          it as opaque address bytes, same as a Shelley address binary.

  Strict / Harvard: never `binary_to_term`/`String.to_atom`; preserve byte-exact `raw` per tx
  and the byte-exact address. Never raises — returns `{:error, _}` on anything malformed.
  """

  alias Cardamom.Crypto

  require Logger

  @type input :: {binary(), non_neg_integer()}
  @type output :: %{
          address: binary(),
          value: non_neg_integer(),
          multiasset: nil,
          datum_hash: nil,
          datum: nil,
          raw: binary()
        }
  @type tx :: %{
          txid: binary(),
          valid: true,
          inputs: [input()],
          outputs: [output()],
          reference_inputs: [],
          collateral_inputs: [],
          collateral_return: nil,
          fee: nil,
          mint: nil
        }

  @doc """
  Decode all transactions in a Byron block's raw bytes (the era-wrapped `[era=0, inner]`
  envelope, OR a bare Byron `[tag, content]` block). Returns `{:ok, [tx]}`. An epoch-boundary
  block (EBB, tag 0) carries NO transactions → `{:ok, []}`. Strict: never raises.
  """
  @spec txs_in(binary()) :: {:ok, [tx()]} | {:error, term()}
  def txs_in(raw) when is_binary(raw) do
    with {:ok, inner} <- unwrap_era(raw),
         {:ok, tx_payload_bytes} <- tx_payload_bytes(inner) do
      {:ok, decode_tx_payload(tx_payload_bytes)}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  def txs_in(_), do: {:error, :not_binary}

  # ---- envelope ----

  # `[era, inner]` (0x82) → inner's original bytes. A bare Byron block starts with the
  # array-2 `[tag, content]` (also 0x82) — but so does `[era, inner]`. We disambiguate by the
  # known Cardano network shape: era-wrapped blocks are `[era=0, [tag, content]]`. When the
  # FIRST element is 0 we can't tell `[era=0, block]` from `[tag=0(EBB), boundary]` by the tag
  # alone; we try the era-wrapped reading first (the network shape) and fall back to treating
  # the input as a bare block. (EBBs carry no txs either way, so a misread yields `{:ok, []}`.)
  defp unwrap_era(<<0x82, rest::binary>> = whole) do
    case CBOR.decode(rest) do
      {:ok, era, inner} when is_integer(era) and is_binary(inner) and byte_size(inner) > 0 ->
        # `inner` should itself be a Byron `[tag, content]` array — if so, this was era-wrapped.
        case inner do
          <<0x82, _::binary>> -> {:ok, inner}
          # First element was an int but the rest isn't a [tag, content] block: treat the whole
          # thing as a bare block (the leading int WAS the tag).
          _ -> {:ok, whole}
        end

      _ ->
        {:ok, whole}
    end
  end

  defp unwrap_era(_), do: {:error, :not_byron_block}

  # `inner` = Byron `[tag, content]`. tag 1 = regular block `[header, body, extra]`; tag 0 =
  # EBB (no txs). Return the byte-exact txPayload (body element 0), or signal "no txs".
  defp tx_payload_bytes(<<0x82, rest::binary>>) do
    {tag_bytes, content_bytes} = take(rest)

    case CBOR.decode(tag_bytes) do
      {:ok, 1, _} -> regular_block_tx_payload(content_bytes)
      {:ok, 0, _} -> {:ok, :no_txs}
      _ -> {:error, :bad_byron_block_tag}
    end
  end

  defp tx_payload_bytes(_), do: {:error, :not_byron_block}

  # Regular block content = `[header, body, extra_body_data]` (array-3). body = element 1.
  defp regular_block_tx_payload(content) do
    with {:ok, rest0} <- array_header(content, 3),
         {_hdr, rest1} <- take(rest0),
         {body, _rest2} <- take(rest1) do
      body_tx_payload(body)
    end
  end

  # body = `[txPayload, ssc, dlg, update]` (array-4). txPayload = element 0.
  defp body_tx_payload(body) do
    with {:ok, rest0} <- array_header(body, 4),
         {tx_payload, _rest} <- take(rest0) do
      {:ok, tx_payload}
    end
  end

  # ---- txPayload → txs ----

  defp decode_tx_payload(:no_txs), do: []

  defp decode_tx_payload(tx_payload_bytes) do
    # txPayload is a CBOR array of TxAux (`[tx, witness]`). Carve each TxAux's byte span, then
    # carve the tx (element 0) within it so its byte-exact bytes → txid.
    case split_array(tx_payload_bytes) do
      {:ok, aux_spans} -> Enum.map(aux_spans, &decode_tx_aux/1)
      {:error, _} -> []
    end
  end

  # TxAux = `[tx, witness]` (array-2). Decode the tx (element 0); drop the witness.
  defp decode_tx_aux(aux_bytes) do
    {:ok, rest0} = array_header(aux_bytes, 2)
    {tx_bytes, _witness} = take(rest0)
    decode_tx(tx_bytes)
  end

  # Tx = `[inputs, outputs, attributes]` (array-3). txid = blake2b_256 of these ORIGINAL bytes.
  defp decode_tx(tx_bytes) do
    {:ok, [inputs, outputs | _attrs], _} = CBOR.decode(tx_bytes)

    %{
      txid: Crypto.blake2b_256(tx_bytes),
      valid: true,
      inputs: decode_inputs(inputs),
      outputs: decode_outputs(outputs),
      reference_inputs: [],
      collateral_inputs: [],
      collateral_return: nil,
      fee: nil,
      mint: nil
    }
  end

  # inputs: array of TxIn = `[0, #6.24(bytes-of-cbor([txid, index]))]`.
  defp decode_inputs(inputs) when is_list(inputs) do
    Enum.flat_map(inputs, fn
      [0, %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: nested}}] ->
        case CBOR.decode(nested) do
          {:ok, [%CBOR.Tag{tag: :bytes, value: txid}, index], _} -> [{txid, index}]
          _ -> []
        end

      other ->
        Logger.debug(fn -> "Byron.Body: skipping unrecognised TxIn shape: #{inspect(other)}" end)
        []
    end)
  end

  defp decode_inputs(_), do: []

  # outputs: array of TxOut = `[address, lovelace]`. address kept as byte-exact CBOR re-encode.
  defp decode_outputs(outputs) when is_list(outputs) do
    Enum.map(outputs, fn [address, lovelace] ->
      %{
        address: CBOR.encode(address),
        value: lovelace,
        multiasset: nil,
        datum_hash: nil,
        datum: nil,
        raw: CBOR.encode([address, lovelace])
      }
    end)
  end

  defp decode_outputs(_), do: []

  # ---- byte-span helpers (mirror Conway.Tx) ----

  # Assert+consume a definite array header of exactly `n` items (n < 24, single-byte header).
  defp array_header(<<head, rest::binary>>, n) when head == 0x80 + n, do: {:ok, rest}
  defp array_header(_, _), do: {:error, :bad_byron_array}

  # Split an array of items into each item's ORIGINAL byte span. Byron txPayload uses a
  # definite-length array; handle the small (0x80..0x97) and 1-byte-count (0x98) headers, plus
  # the indefinite-length array (0x9F .. 0xFF "break") that Byron payloads can also use.
  defp split_array(<<0x9F, rest::binary>>), do: {:ok, take_until_break(rest, [])}

  defp split_array(<<head, rest::binary>>) when head >= 0x80 and head <= 0x97 do
    {:ok, take_n(rest, head - 0x80, [])}
  end

  defp split_array(<<0x98, n, rest::binary>>), do: {:ok, take_n(rest, n, [])}
  defp split_array(<<0x99, n::16, rest::binary>>), do: {:ok, take_n(rest, n, [])}
  defp split_array(_), do: {:error, :bad_tx_payload}

  defp take_n(_bin, 0, acc), do: Enum.reverse(acc)

  defp take_n(bin, n, acc) do
    {item, rest} = take(bin)
    take_n(rest, n - 1, [item | acc])
  end

  # Indefinite array: items until the 0xFF break byte.
  defp take_until_break(<<0xFF, _::binary>>, acc), do: Enum.reverse(acc)

  defp take_until_break(bin, acc) do
    {item, rest} = take(bin)
    take_until_break(rest, [item | acc])
  end

  # Decode one CBOR item; return {its original bytes, rest}.
  defp take(bin) do
    {:ok, _term, rest} = CBOR.decode(bin)
    span = byte_size(bin) - byte_size(rest)
    <<item::binary-size(span), ^rest::binary>> = bin
    {item, rest}
  end
end
