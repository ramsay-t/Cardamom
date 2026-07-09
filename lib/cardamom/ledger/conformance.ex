defmodule Cardamom.Ledger.Conformance do
  @moduledoc """
  On-chain CONFORMANCE oracles: the ledger state never flows over the wire, so we can't compare
  state dumps with the network. Instead the chain IMPLICITLY COMMITS to it — every tx the network
  accepted must satisfy the ledger rules against OUR derived state. We assert those constraints
  and treat a failure as a DIVERGENCE signal (our derived state has drifted), NOT a rejection: as
  an observer we never drop a tx the network already accepted — a failing check means OUR bug.

  FIRST ORACLE: VALUE CONSERVATION (Conway Agda Utxo.lagda.md:437-449, 547 — `consumed ≡ produced`):

      consumed = balance(inputs)  + mint_ada + depositRefunds + Σ withdrawals
      produced = balance(outputs) + fee      + depositsMade   + donation

  where balance(inputs) resolves each input `(txid, ix)` to its value in OUR UTxO set — so this
  ALSO self-checks our UTxO tracking: if a stored output's value is wrong, or an input we can't
  resolve, the equation won't balance.

  HONESTY / STAGED: `depositsMade`/`depositRefunds` need CERTIFICATE decoding (Tier a, not yet),
  and `mint` non-ADA / multi-asset balancing is out of scope for the ADA-coin equation. So we only
  ASSERT on txs where the equation is COMPLETE with what we have — a simple value-moving tx (all
  inputs resolvable, no certs, ADA-only). Anything else returns `{:skip, reason}` so we never
  false-alarm on an equation we can't yet fully compute. As Tier (a) lands, the skip conditions
  shrink and coverage grows.
  """

  require Logger
  alias Cardamom.ChainStore

  @doc """
  Check value conservation for one decoded tx. Returns:
    * `:ok`               — the (complete) equation balanced,
    * `{:skip, reason}`   — we can't fully compute it yet (certs, unresolved input, non-ADA) — no verdict,
    * `{:diverge, detail}`— it DID NOT balance ⇒ our derived state has drifted (logged + telemetry).
  Never raises; never rejects. `valid?` note: an INVALID (phase-2) tx conserves over COLLATERAL,
  not inputs/outputs — a different equation — so we skip those here (collateral conformance is a
  later oracle).
  """
  @spec check_value_conservation(map()) :: :ok | {:skip, term()} | {:diverge, map()}
  def check_value_conservation(%{valid: false}), do: {:skip, :invalid_tx_collateral_path}

  def check_value_conservation(%{valid: true} = tx) do
    cond do
      has_certs?(tx) ->
        # certs carry deposit/refund terms we don't decode yet → equation incomplete.
        {:skip, :has_certs}

      multiasset_present?(tx) ->
        {:skip, :multiasset_not_balanced}

      true ->
        balance_simple(tx)
    end
  end

  def check_value_conservation(_), do: {:skip, :not_a_tx}

  # The ADA-coin equation for a simple value-moving tx:
  #   Σ input_values + Σ withdrawals  ==  Σ output_values + fee + donation
  # (no certs ⇒ no deposits/refunds; ADA-only ⇒ no asset terms).
  defp balance_simple(%{inputs: inputs, outputs: outputs} = tx) do
    case resolve_inputs(inputs) do
      {:ok, in_sum} ->
        withdrawals = tx |> Map.get(:withdrawals, []) |> Enum.reduce(0, fn {_a, c}, s -> s + c end)
        out_sum = Enum.reduce(outputs, 0, fn o, s -> s + (o.value || 0) end)
        fee = Map.get(tx, :fee) || 0
        donation = Map.get(tx, :donation) || 0

        consumed = in_sum + withdrawals
        produced = out_sum + fee + donation

        if consumed == produced do
          :ok
        else
          detail = %{
            txid: hex(tx.txid),
            consumed: consumed,
            produced: produced,
            diff: consumed - produced,
            inputs: in_sum,
            withdrawals: withdrawals,
            outputs: out_sum,
            fee: fee,
            donation: donation
          }

          Logger.warning("ledger conformance DIVERGENCE (value conservation): #{inspect(detail)}")

          :telemetry.execute([:cardamom, :ledger, :divergence], %{diff: detail.diff}, %{
            check: :value_conservation,
            txid: detail.txid
          })

          {:diverge, detail}
        end

      {:unresolved, ref} ->
        # An input we don't have in our UTxO set yet (cross-block/out-of-order backfill, or a
        # genesis UTxO not seeded). Can't compute balance(inputs) → no verdict, not a divergence.
        {:skip, {:unresolved_input, ref}}
    end
  end

  # Sum the values of the resolved inputs, or bail with the first unresolvable ref.
  defp resolve_inputs(inputs) do
    Enum.reduce_while(inputs, {:ok, 0}, fn {txid, ix}, {:ok, acc} ->
      case ChainStore.txo(txid, ix) do
        %{value: v} when is_integer(v) -> {:cont, {:ok, acc + v}}
        _ -> {:halt, {:unresolved, {hex(txid), ix}}}
      end
    end)
  end

  defp has_certs?(%{certs: c}) when is_list(c) and c != [], do: true
  defp has_certs?(_), do: false

  # ADA-only if every output's value is a bare integer (coin/1); a multiasset output decodes with
  # a non-nil multiasset map and can't be balanced by the ADA equation alone.
  defp multiasset_present?(%{outputs: outputs}) do
    Enum.any?(outputs, fn o -> match?(%{multiasset: m} when m not in [nil, %{}], o) end)
  end

  defp multiasset_present?(_), do: false

  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)
  defp hex(other), do: inspect(other)
end
