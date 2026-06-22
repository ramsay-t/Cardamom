defmodule Cardamom.Ledger.Conway.Tx do
  @moduledoc """
  Decode the transactions out of a Conway block. A block is
  `[era, [header, tx_bodies, tx_witness_sets, aux_data, invalid_txs]]`; `tx_bodies` is
  an array of transaction bodies. For each tx we extract:

    * `txid`    — blake2b-256 of the tx body's ORIGINAL CBOR bytes (byte-exact, NOT
                  re-encoded). This is the identity a spending tx's input references, so
                  it must match the wire exactly — we carve per-tx byte spans, never
                  re-encode the decoded term.
    * `inputs`  — `[{txid, index}]`, the TXOs this tx SPENDS (transaction_body key 0).
    * `outputs` — `[%{address, value, datum_hash, datum, raw}]`, the new TXOs this tx
                  CREATES (key 1). `value` is lovelace (multi-asset folded later).

  Witnesses / certs / mint / validity are not decoded — they live in the block raw
  (Blocks table) and aren't needed for TXO tracking (goal b). Strict: never raises;
  returns `{:error, _}` on anything malformed.

  transaction_output (Conway) is either the legacy array `[address, value, ?datum_hash]`
  or the post-Babbage map `{0: address, 1: value, 2: datum_option, 3: script_ref}`.
  Both are handled.
  """

  alias Cardamom.Crypto

  @type input :: {binary(), non_neg_integer()}
  @type output :: %{
          address: binary(),
          value: non_neg_integer(),
          datum_hash: binary() | nil,
          datum: term() | nil,
          raw: binary()
        }
  @type tx :: %{txid: binary(), inputs: [input()], outputs: [output()]}

  @doc "Decode all transactions in a block's raw bytes."
  @spec txs_in(binary()) :: {:ok, [tx()]} | {:error, term()}
  def txs_in(raw) when is_binary(raw) do
    with {:ok, bodies_bytes} <- tx_bodies_bytes(raw),
         {:ok, body_spans} <- split_array(bodies_bytes) do
      {:ok, Enum.map(body_spans, &decode_body/1)}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  def txs_in(_), do: {:error, :not_binary}

  # ---- one tx body (byte span) → tx map ----

  defp decode_body(body_bytes) do
    {:ok, body, _} = CBOR.decode(body_bytes)
    %{
      txid: Crypto.blake2b_256(body_bytes),
      inputs: decode_inputs(Map.get(body, 0)),
      outputs: decode_outputs(Map.get(body, 1))
    }
  end

  # inputs (key 0): a set/array of [tx_hash(bytes), index].
  defp decode_inputs(nil), do: []

  defp decode_inputs(inputs) when is_list(inputs) do
    Enum.map(inputs, fn [%CBOR.Tag{tag: :bytes, value: h}, ix] -> {h, ix} end)
  end

  # outputs (key 1): array of transaction_output. Carve byte spans so each output's raw
  # is preserved verbatim (forensic), then decode each shape.
  defp decode_outputs(nil), do: []

  defp decode_outputs(outputs) when is_list(outputs) do
    Enum.map(outputs, &decode_output/1)
  end

  # Legacy array output: [address, value, ?datum_hash].
  defp decode_output([addr, value | rest]) do
    %{
      address: unbytes(addr),
      value: coin(value),
      datum_hash: legacy_datum_hash(rest),
      datum: nil,
      raw: CBOR.encode([addr, value | rest])
    }
  end

  # Post-Babbage map output: {0: address, 1: value, 2: datum_option, 3: script_ref}.
  defp decode_output(%{} = o) do
    %{
      address: unbytes(Map.get(o, 0)),
      value: coin(Map.get(o, 1)),
      datum_hash: datum_hash_of(Map.get(o, 2)),
      datum: inline_datum_of(Map.get(o, 2)),
      raw: CBOR.encode(o)
    }
  end

  defp legacy_datum_hash([%CBOR.Tag{tag: :bytes, value: h}]), do: h
  defp legacy_datum_hash(_), do: nil

  # datum_option = [0, hash] (hash) or [1, #6.24(datum)] (inline datum).
  defp datum_hash_of([0, %CBOR.Tag{tag: :bytes, value: h}]), do: h
  defp datum_hash_of(_), do: nil

  defp inline_datum_of([1, datum]), do: datum
  defp inline_datum_of(_), do: nil

  # value: a bare coin (uint) or [coin, multiasset]. We track lovelace; assets later.
  defp coin(v) when is_integer(v), do: v
  defp coin([coin | _assets]) when is_integer(coin), do: coin
  defp coin(_), do: 0

  defp unbytes(%CBOR.Tag{tag: :bytes, value: b}), do: b
  defp unbytes(b) when is_binary(b), do: b
  defp unbytes(_), do: <<>>

  # ---- get the tx_bodies array bytes out of the block (byte-exact) ----

  defp tx_bodies_bytes(raw) do
    with {:ok, inner} <- unwrap_era(raw),
         <<0x85, rest0::binary>> <- inner,
         {_hdr, rest1} <- take(rest0),
         {bodies, _rest2} <- take(rest1) do
      {:ok, bodies}
    else
      _ -> {:error, :bad_block_structure}
    end
  end

  # [era, inner] (0x82) → inner's original bytes; bare array(5) (0x85) → as-is.
  defp unwrap_era(<<0x85, _::binary>> = bare), do: {:ok, bare}

  defp unwrap_era(<<0x82, rest::binary>>) do
    {:ok, _era, inner} = CBOR.decode(rest)
    {:ok, inner}
  end

  defp unwrap_era(_), do: {:error, :not_block_envelope}

  # Split an `array(N)` of items into the list of each item's ORIGINAL byte span.
  defp split_array(<<head, _::binary>> = bin) when head >= 0x80 and head <= 0x97 do
    n = head - 0x80
    <<_::8, rest::binary>> = bin
    {:ok, take_n(rest, n, [])}
  end

  # array with a 1-byte count (0x98 NN) — larger blocks.
  defp split_array(<<0x98, n, rest::binary>>), do: {:ok, take_n(rest, n, [])}
  defp split_array(_), do: {:error, :bad_tx_bodies}

  defp take_n(_bin, 0, acc), do: Enum.reverse(acc)

  defp take_n(bin, n, acc) do
    {item, rest} = take(bin)
    take_n(rest, n - 1, [item | acc])
  end

  # Decode one CBOR item; return {its original bytes, rest}.
  defp take(bin) do
    {:ok, _term, rest} = CBOR.decode(bin)
    span = byte_size(bin) - byte_size(rest)
    <<item::binary-size(span), ^rest::binary>> = bin
    {item, rest}
  end
end
