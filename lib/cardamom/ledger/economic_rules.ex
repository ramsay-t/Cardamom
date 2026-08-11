defmodule Cardamom.Ledger.EconomicRules do
  @moduledoc """
  Phase-1 ECONOMIC / structural transaction rules (Conway UTXO), each a verdict tuple
  `{rule, :pass | {:skip, reason} | {:violation, detail}, opts}` stamped with the tx's `:txid`.
  Pure; all context (block slot, protocol params) injected via `ctx`.

  Rules:
    * `:validity_interval` — the applying block's slot ∈ [invalid_before, invalid_hereafter),
      lower INCLUSIVE, upper EXCLUSIVE (Utxo.lagda.md, `slot ∈ txvldt`). Absent bound = unbounded.
      SKIPS if the slot is unknown.
    * `:min_fee` — `fee ≥ minFee`. True minFee = `a·|tx| + b (+ Conway refScript tier)` over the
      WHOLE tx; we only have the tx BODY size per tx, so we assert the NECESSARY LOWER BOUND
      `fee ≥ a·body_size + b` — a genuine underpayment still trips it and we never over-reject
      (witnesses only make the true minFee larger). SKIPS when `a`/`b` are absent (pp-tracking).
    * `:min_ada` — every output's coin ≥ `minUTxO(output) = coinsPerUTxOByte · (|output| + 160)`
      (the Babbage constant-overhead form). SKIPS when `coinsPerUTxOByte` is unknown — Preview
      conway-genesis omits it (it's an ENACTED param, not genesis; honest skip until pp-tracking).
    * `:max_tx_size` — `body_size ≤ maxTxSize`. SKIPS when the cap is absent.

  `ctx` keys (all optional; a missing one SKIPS its rule): `:slot`, `:min_fee_a`, `:min_fee_b`,
  `:coins_per_utxo_byte`, `:max_tx_size`.
  """

  # Babbage min-UTxO per-output byte overhead (constant 160 in the coinsPerUTxOByte formula).
  @utxo_overhead 160

  @doc "Run the economic/structural rules for one decoded tx against `ctx`."
  def check(tx, ctx) when is_map(tx) and is_map(ctx) do
    txid = Map.get(tx, :txid)

    [
      validity_interval(tx, ctx),
      min_fee(tx, ctx),
      min_ada(tx, ctx),
      max_tx_size(tx, ctx)
    ]
    |> Enum.map(fn {rule, outcome} -> {rule, outcome, [txid: txid]} end)
  end

  # ---- validity interval ----

  defp validity_interval(tx, ctx) do
    case Map.get(ctx, :slot) do
      slot when is_integer(slot) ->
        lo = Map.get(tx, :invalid_before)
        hi = Map.get(tx, :invalid_hereafter)

        cond do
          is_integer(lo) and slot < lo ->
            {:validity_interval, {:violation, %{slot: slot, invalid_before: lo}}}

          is_integer(hi) and slot >= hi ->
            {:validity_interval, {:violation, %{slot: slot, invalid_hereafter: hi}}}

          true ->
            {:validity_interval, :pass}
        end

      _ ->
        {:validity_interval, {:skip, :slot_unknown}}
    end
  end

  # ---- min fee (necessary lower bound over the body size) ----

  defp min_fee(tx, ctx) do
    with a when is_integer(a) <- Map.get(ctx, :min_fee_a),
         b when is_integer(b) <- Map.get(ctx, :min_fee_b),
         size when is_integer(size) <- Map.get(tx, :body_size),
         fee when is_integer(fee) <- Map.get(tx, :fee) do
      bound = a * size + b

      if fee >= bound,
        do: {:min_fee, :pass},
        else: {:min_fee, {:violation, %{fee: fee, min_bound: bound}}}
    else
      _ -> {:min_fee, {:skip, :fee_params_or_fields_absent}}
    end
  end

  # ---- min ada per output ----

  defp min_ada(tx, ctx) do
    case {Map.get(ctx, :coins_per_utxo_byte), Map.get(tx, :outputs)} do
      {cpb, outputs} when is_integer(cpb) and is_list(outputs) ->
        under =
          Enum.filter(outputs, fn o ->
            coin = o[:value] || 0
            size = output_size(o)
            is_integer(coin) and coin < cpb * (size + @utxo_overhead)
          end)

        if under == [],
          do: {:min_ada, :pass},
          else: {:min_ada, {:violation, %{under_min: length(under)}}}

      _ ->
        {:min_ada, {:skip, :coins_per_utxo_byte_unknown}}
    end
  end

  defp output_size(%{raw: raw}) when is_binary(raw), do: byte_size(raw)
  defp output_size(_), do: 0

  # ---- max tx size ----

  defp max_tx_size(tx, ctx) do
    with cap when is_integer(cap) <- Map.get(ctx, :max_tx_size),
         size when is_integer(size) <- Map.get(tx, :body_size) do
      if size <= cap,
        do: {:max_tx_size, :pass},
        else: {:max_tx_size, {:violation, %{body_size: size, max: cap}}}
    else
      _ -> {:max_tx_size, {:skip, :max_tx_size_unknown}}
    end
  end
end
