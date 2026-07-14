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

  CERT DEPOSIT TERMS: `depositsMade`/`depositRefunds` are costed from the DECODED certs
  (`Cardamom.Ledger.Conway.Cert`): Conway certs carry their deposit/refund coin EXPLICITLY
  (tags 7/8/11/12/13/16/17 — and the ledger rules require the stated coin to equal the recorded
  deposit, so the cert IS the amount); the deprecated no-coin forms (tags 0/1) are costed at the
  protocol's keyDeposit. CAVEAT (recorded, accepted): a tag-1 refund is really the amount
  RECORDED at registration — costing it at the current keyDeposit is exact unless keyDeposit
  changed in between (it never has on Preview); a drift here surfaces as divergence, which is
  the point.

  HONESTY / STAGED — the remaining skips, each an equation term we can't yet compute:
    * pool_registration cert — the deposit is charged ONLY if the pool is new (state- and
      same-block-order-dependent; not derivable from the cert alone),
    * governance proposals (body key 20) — each carries a govActionDeposit (gov tracking TODO),
    * unknown/undecodable cert types,
    * multi-asset outputs (the ADA-coin equation can't balance assets),
    * an unresolved input (its block not processed yet).
  Anything else is ASSERTED. A skip returns `{:skip, reason}` so we never false-alarm.
  """

  require Logger
  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Conway.Cert

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
      has_proposals?(tx) ->
        # each proposal carries a govActionDeposit (produced term) — gov decoding TODO.
        {:skip, :has_gov_proposals}

      multiasset_present?(tx) ->
        {:skip, :multiasset_not_balanced}

      true ->
        case cert_deposit_terms(Cert.decode_all(Map.get(tx, :certs)), ChainStore.protocol_deposits()) do
          {:ok, made, refunds} -> balance(tx, made, refunds)
          {:skip, reason} -> {:skip, reason}
        end
    end
  end

  def check_value_conservation(_), do: {:skip, :not_a_tx}

  @doc """
  The tx's deposit terms for the conservation equation, from its decoded certs:
  `{:ok, depositsMade, depositRefunds}` or `{:skip, reason}` when a cert's term isn't derivable
  from the cert alone. Explicit-coin certs state their amount (the ledger rules require it to
  match the recorded deposit); deprecated no-coin stake reg/dereg cost the protocol keyDeposit.
  """
  def cert_deposit_terms(certs, pp) do
    Enum.reduce_while(certs, {:ok, 0, 0}, fn cert, {:ok, made, refunds} ->
      case deposit_term(cert, pp) do
        {:made, n} -> {:cont, {:ok, made + n, refunds}}
        {:refund, n} -> {:cont, {:ok, made, refunds + n}}
        :none -> {:cont, {:ok, made, refunds}}
        {:skip, reason} -> {:halt, {:skip, reason}}
      end
    end)
  end

  # Explicit-coin Conway forms — the cert states the amount.
  defp deposit_term(%{type: :stake_registration, deposit: n}, _pp), do: {:made, n}
  defp deposit_term(%{type: :stake_deregistration, refund: n}, _pp), do: {:refund, n}
  defp deposit_term(%{type: :stake_registration_and_delegation, deposit: n}, _pp), do: {:made, n}
  defp deposit_term(%{type: :vote_registration_and_delegation, deposit: n}, _pp), do: {:made, n}
  defp deposit_term(%{type: :stake_vote_registration_and_delegation, deposit: n}, _pp), do: {:made, n}
  defp deposit_term(%{type: :drep_registration, deposit: n}, _pp), do: {:made, n}
  defp deposit_term(%{type: :drep_deregistration, refund: n}, _pp), do: {:refund, n}

  # Deprecated no-coin stake reg/dereg (tags 0/1): the protocol keyDeposit (see moduledoc caveat).
  defp deposit_term(%{type: :stake_registration}, pp), do: {:made, pp.key_deposit}
  defp deposit_term(%{type: :stake_deregistration}, pp), do: {:refund, pp.key_deposit}

  # No value flow: delegations, pool retirement (refund happens at POOLREAP, not in a tx),
  # DRep update, committee certs.
  defp deposit_term(%{type: t}, _pp)
       when t in ~w(stake_delegation vote_delegation stake_and_vote_delegation pool_retirement
                    drep_update committee_hot_auth committee_resignation)a,
       do: :none

  # Pool registration: deposit charged ONLY if the pool is NEW — not derivable from the cert.
  defp deposit_term(%{type: :pool_registration}, _pp), do: {:skip, :pool_reg_deposit_state_dependent}

  defp deposit_term(%{type: :unknown} = c, _pp), do: {:skip, {:unknown_cert, Map.get(c, :tag)}}
  defp deposit_term(_other, _pp), do: {:skip, :undecodable_cert}

  # The ADA-coin conservation equation (Utxo.lagda.md:437-449):
  #   Σ input_values + Σ withdrawals + depositRefunds == Σ output_values + fee + depositsMade + donation
  defp balance(%{inputs: inputs, outputs: outputs} = tx, deposits_made, deposit_refunds) do
    case resolve_inputs(inputs) do
      {:ok, in_sum} ->
        withdrawals = tx |> Map.get(:withdrawals, []) |> Enum.reduce(0, fn {_a, c}, s -> s + c end)
        out_sum = Enum.reduce(outputs, 0, fn o, s -> s + (o.value || 0) end)
        fee = Map.get(tx, :fee) || 0
        donation = Map.get(tx, :donation) || 0

        consumed = in_sum + withdrawals + deposit_refunds
        produced = out_sum + fee + deposits_made + donation

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
            deposit_refunds: deposit_refunds,
            outputs: out_sum,
            fee: fee,
            deposits_made: deposits_made,
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

  defp has_proposals?(%{proposals: p}) when is_list(p) and p != [], do: true
  defp has_proposals?(%{proposals: %CBOR.Tag{tag: 258, value: p}}) when is_list(p) and p != [], do: true
  defp has_proposals?(_), do: false

  # ADA-only if every output's value is a bare integer (coin/1); a multiasset output decodes with
  # a non-nil multiasset map and can't be balanced by the ADA equation alone.
  defp multiasset_present?(%{outputs: outputs}) do
    Enum.any?(outputs, fn o -> match?(%{multiasset: m} when m not in [nil, %{}], o) end)
  end

  defp multiasset_present?(_), do: false

  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)
  defp hex(other), do: inspect(other)
end
