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
    * `outputs` — `[%{address, value, multiasset, datum_hash, datum, raw}]`, the new TXOs
                  this tx CREATES (key 1). `value` is the lovelace coin; `multiasset` is the
                  full `{policy_id => {asset_name => amount}}` token bundle (nil for ADA-only).

  Witnesses / certs / mint / validity are not decoded — they live in the block raw
  (Blocks table) and aren't needed for TXO tracking (goal b). Strict: never raises;
  returns `{:error, _}` on anything malformed.

  transaction_output (Conway) is either the legacy array `[address, value, ?datum_hash]`
  or the post-Babbage map `{0: address, 1: value, 2: datum_option, 3: script_ref}`.
  Both are handled.
  """

  alias Cardamom.Crypto

  @type input :: {binary(), non_neg_integer()}
  @type multiasset :: %{optional(binary()) => %{optional(binary()) => non_neg_integer()}}
  @type output :: %{
          address: binary(),
          value: non_neg_integer(),
          multiasset: multiasset() | nil,
          datum_hash: binary() | nil,
          datum: term() | nil,
          raw: binary()
        }
  @type tx :: %{txid: binary(), inputs: [input()], outputs: [output()]}

  @doc """
  Decode all transactions in a block's raw bytes. Each tx is tagged `valid: true|false`
  from the block body's `invalid_transactions` list (5th segment = indices of txs that
  FAILED PHASE-2 script validation). An invalid tx must NOT have its normal inputs/outputs
  applied — its COLLATERAL is consumed instead; callers branch on `valid`.
  """
  @spec txs_in(binary()) :: {:ok, [tx()]} | {:error, term()}
  def txs_in(raw) when is_binary(raw) do
    with {:ok, bodies_bytes, invalid_bytes} <- bodies_and_invalid(raw),
         {:ok, body_spans} <- split_array(bodies_bytes) do
      invalid_set = invalid_indices(invalid_bytes)

      txs =
        body_spans
        |> Enum.with_index()
        |> Enum.map(fn {span, ix} -> decode_body(span, not MapSet.member?(invalid_set, ix)) end)

      {:ok, txs}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  def txs_in(_), do: {:error, :not_binary}

  # The invalid_transactions segment is a CBOR array of uint indices into tx_bodies.
  defp invalid_indices(invalid_bytes) do
    case CBOR.decode(invalid_bytes) do
      {:ok, ixs, _} when is_list(ixs) -> MapSet.new(ixs)
      _ -> MapSet.new()
    end
  end

  @doc """
  Decode a STANDALONE tx body's bytes (as delivered by TxSubmission MsgReplyTxs — a tx
  not wrapped in a block) into the same tx map as txs_in/1. The txid is the byte-exact
  blake2b-256 of these bytes.
  """
  @spec decode_tx(binary()) :: {:ok, tx()} | {:error, term()}
  def decode_tx(body_bytes) when is_binary(body_bytes) do
    # A standalone tx (e.g. from the mempool) carries no block-level validity verdict —
    # treat as valid; the chain decides validity only when it lands in a block.
    {:ok, decode_body(body_bytes, true)}
  rescue
    e -> {:error, {:exception, e}}
  end

  def decode_tx(_), do: {:error, :not_binary}

  # ---- one tx body (byte span) → tx map ----

  # tx_body keys: 0 inputs, 1 outputs, 13 collateral inputs, 16 collateral return output.
  defp decode_body(body_bytes, valid?) do
    {:ok, body, _} = CBOR.decode(body_bytes)

    %{
      txid: Crypto.blake2b_256(body_bytes),
      valid: valid?,
      inputs: decode_inputs(Map.get(body, 0)),
      outputs: decode_outputs(Map.get(body, 1)),
      # reference_inputs (key 18): Ξ — read-only, NOT consumed (Agda: refInputs ⊆ dom utxo
      # but absent from the state update). Must be unspent; a spend of one elsewhere
      # invalidates this reader.
      reference_inputs: decode_inputs(Map.get(body, 18)),
      # Phase-2 (invalid-tx) consumption: collateral inputs spent, collateral-return made.
      collateral_inputs: decode_inputs(Map.get(body, 13)),
      collateral_return: decode_collateral_return(Map.get(body, 16)),
      # fee (key 2) and mint (key 9) — kept raw for phase-1 checks (mint must contain no ADA).
      fee: Map.get(body, 2),
      mint: Map.get(body, 9)
    }
  end

  defp decode_collateral_return(nil), do: nil
  defp decode_collateral_return(out), do: decode_output(out)

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
      multiasset: multiasset(value),
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
      multiasset: multiasset(Map.get(o, 1)),
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

  # value (Conway CDDL line 174): `coin/ [coin, multiasset<positive_coin>]`. A bare uint is
  # ADA-only (Shelley has NO multiasset at all — shelley.cddl `value = coin`); Mary+ adds the
  # `[coin, multiasset]` pair. `coin/1` keeps the lovelace integer for back-compat.
  defp coin(v) when is_integer(v), do: v
  defp coin([coin | _assets]) when is_integer(coin), do: coin
  defp coin(_), do: 0

  # multiasset (Conway CDDL line 178): `{* policy_id => {+ asset_name => a0}}`. Preserve the
  # whole token bundle, unwrapping CBOR byte-tags (policy_id = script_hash 28B, asset_name =
  # bytes .size 0..32) to raw binaries. nil for a bare-coin (ADA-only / Shelley) value.
  defp multiasset(v) when is_integer(v), do: nil
  defp multiasset([_coin, ma]) when is_map(ma), do: unwrap_multiasset(ma)
  defp multiasset([_coin | _]), do: nil
  defp multiasset(_), do: nil

  defp unwrap_multiasset(ma) do
    Map.new(ma, fn {policy_id, assets} ->
      {unbytes(policy_id), Map.new(assets, fn {name, amt} -> {unbytes(name), amt} end)}
    end)
  end

  defp unbytes(%CBOR.Tag{tag: :bytes, value: b}), do: b
  defp unbytes(b) when is_binary(b), do: b
  defp unbytes(_), do: <<>>

  # ---- get the tx_bodies array bytes out of the block (byte-exact) ----

  # Block body = [header, tx_bodies, witnesses, aux, invalid_transactions]. Return the
  # byte-exact tx_bodies segment AND the invalid_transactions segment (5th).
  defp bodies_and_invalid(raw) do
    with {:ok, inner} <- unwrap_era(raw),
         <<0x85, rest0::binary>> <- inner,
         {_hdr, rest1} <- take(rest0),
         {bodies, rest2} <- take(rest1),
         {_wits, rest3} <- take(rest2),
         {_aux, rest4} <- take(rest3),
         {invalid, _rest5} <- take(rest4) do
      {:ok, bodies, invalid}
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
