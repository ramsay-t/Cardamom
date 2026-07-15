defmodule Cardamom.Ledger.Verdict do
  @moduledoc """
  The block VALIDATION VERDICT — the validator architecture, arriving via the observer.

  Mirrors the header gate (`Cardamom.Ledger.HeaderHandler`: decode → VALIDATE → store): the
  block's ledger checks RETURN results instead of fire-and-forget telemetry, this module
  aggregates them into one per-block verdict, and the verdict is rendered BEFORE derived state
  commits. The rules are the on-chain conformance oracles (`Cardamom.Ledger.Conformance`,
  `Cardamom.Ledger.WithdrawalEffects`); each result carries the Agda spec rule it encodes
  (result → spec traceability, same discipline as the tests).

  POLICY (Ramsay, 2026-07-14 — the stop-and-fix stance): a block already ON the chain was
  accepted by the network, so a REJECT verdict on chain load is an ASSERTION FAILURE — expected
  never to fire. When it fires we stop and fix our code (or surface a spec finding); we do NOT
  self-heal and carry on (the old telemetry-only stance buried the signal). Concretely, a
  rejected block parks `txo_processed=false` — a self-announcing stop point: the reconciler
  re-hits it and re-alarms until the code is fixed, and `extract_block_sync` returns
  `{:error, {:validation_rejected, summary}}` so a replay driver halts at the offending block.

  The gate guards DERIVED STATE only (this block's ledger delta + its processed flag). The block
  BYTES stay stored — chain data is ground truth for an observer; it is our derivation that is
  on trial. A future full-node mode gives the same verdict Door-1 consequences instead; the
  verdict/policy split is the seam.

  Decision rule: any `{:violation, _}` ⇒ `:reject`. A `{:skip, _}` NEVER rejects — skips are
  honestly-undecidable checks (see `Conformance`), not violations.
  """

  require Logger

  defstruct hash: nil, slot: nil, results: []

  @type outcome :: :pass | {:skip, term()} | {:violation, term()}
  @type result :: %{rule: atom(), spec: String.t() | nil, outcome: outcome(), txid: binary() | nil}
  @type t :: %__MODULE__{hash: binary() | nil, slot: integer() | nil, results: [result()]}

  # rule → the spec rule it encodes (central + greppable; a rule absent here has spec nil).
  @rule_specs %{
    value_conservation: "Utxo.lagda.md:437-449 (consumed ≡ produced)",
    withdrawal_full_balance: "Certs.lagda.md:596-607 (mapˢ (map₁ stake) (wdrls ˢ) ⊆ rewards ˢ)",
    withdrawal_vote_delegated: "Certs.lagda.md:596-607 (filter isKeyHash wdrlCreds ⊆ dom voteDelegs)",
    withdrawal_decodable: "decode adequacy: the network accepted it, so we must be able to decode it",
    ledger_delta_build: "delta construction integrity (implementation health, not a spec rule)"
  }

  @doc "A fresh verdict for one block (no results yet — accepts)."
  def new(hash, slot), do: %__MODULE__{hash: hash, slot: slot}

  @doc "Record one check result. `opts`: `:txid` — the tx the check ran against, if any."
  def add(%__MODULE__{} = v, rule, outcome, opts \\ []) when is_atom(rule) do
    result = %{rule: rule, spec: Map.get(@rule_specs, rule), outcome: outcome, txid: Keyword.get(opts, :txid)}
    %{v | results: v.results ++ [result]}
  end

  @doc "Fold a list of `{rule, outcome, opts}` results (the shape check modules return) in order."
  def add_all(%__MODULE__{} = v, results) when is_list(results) do
    Enum.reduce(results, v, fn {rule, outcome, opts}, acc -> add(acc, rule, outcome, opts) end)
  end

  @doc "The decision: `:reject` iff any violation; skips never reject."
  def decision(%__MODULE__{results: results}) do
    if Enum.any?(results, &match?(%{outcome: {:violation, _}}, &1)), do: :reject, else: :accept
  end

  @doc "The violating results, compacted to `%{rule, spec, txid (hex), detail}`."
  def violations(%__MODULE__{results: results}) do
    for %{outcome: {:violation, detail}} = r <- results do
      %{rule: r.rule, spec: r.spec, txid: hex(r.txid), detail: detail}
    end
  end

  @doc """
  The compact rendering used as the handler's exit reason and the telemetry metadata:
  hex-keyed, outcome counts, violations in full.
  """
  def summary(%__MODULE__{} = v) do
    %{
      hash: hex(v.hash),
      slot: v.slot,
      decision: decision(v),
      passes: count(v, :pass),
      skips: count(v, :skip),
      violations: violations(v)
    }
  end

  @doc """
  Emit the verdict on the event spine: `[:cardamom, :ledger, :verdict]` with outcome counts as
  measurements and the summary as metadata. A reject also logs loudly (it is an assertion
  failure — see moduledoc); an accept is telemetry-only (every block gets one).
  """
  def emit(%__MODULE__{} = v) do
    s = summary(v)

    if s.decision == :reject do
      Logger.error("block VALIDATION REJECT (stop and fix our code): #{inspect(s)}")
    end

    :telemetry.execute(
      [:cardamom, :ledger, :verdict],
      %{passes: s.passes, skips: s.skips, violations: length(s.violations)},
      s
    )

    v
  end

  defp count(%__MODULE__{results: results}, :pass),
    do: Enum.count(results, &(&1.outcome == :pass))

  defp count(%__MODULE__{results: results}, :skip),
    do: Enum.count(results, &match?(%{outcome: {:skip, _}}, &1))

  defp hex(nil), do: nil
  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)
end
