defmodule Cardamom.Ledger.ParamUpdate do
  @moduledoc """
  ENACTED protocol-parameter tracking — the enactment MECHANISM. A parameter-change gov action,
  once enacted, updates the live protocol-parameter set. We model the live set as a `:pparams`
  ledger domain, one key per parameter, updated by INVERTIBLE per-key delta ops so it journals +
  rolls back exactly like every other ledger effect (`Cardamom.Ledger.Delta`). This is what lets
  the phase-1 economic rules read LIVE parameters instead of a static genesis map — turning the
  min_fee / min_ada checks from skip to assert once a network has enacted the relevant params.

  SCOPE (bounded, honest): this is the enactment mechanism + the read/seed path. The RATIFICATION
  decision — which proposals reach enactment, vote tallies, DRep/committee thresholds, the
  ratification delay — is the governance half of the epoch and a FURTHER layer. Until it lands,
  `enact_ops/2` is driven explicitly (e.g. by a from-genesis replay that knows, from the chain,
  which param-changes were enacted at which boundary); nothing here decides ratification.

  `current_params(defaults, read)` overlays the enacted `:pparams` onto the genesis defaults, so
  a parameter with no enacted change keeps its genesis value.
  """

  @doc """
  The invertible delta ops enacting a decoded `protocol_param_update` (a `%{param => value}` map,
  from `Cardamom.Ledger.Conway.Governance`) against the current params via `read/2`
  (`(:pparams, key) -> value | nil`). One `{:set, :pparams, key, old, new}` per CHANGED param;
  unchanged params produce no op (a no-op set isn't journalled).
  """
  def enact_ops(update, read) when is_map(update) and is_function(read, 2) do
    for {key, new} <- update, (old = read.(:pparams, key)) != new do
      {:set, :pparams, key, old, new}
    end
  end

  @doc """
  The live protocol parameters: genesis `defaults` overlaid with any enacted `:pparams` values.
  `read/2` is the ledger reader; a param absent from `:pparams` keeps its default.
  """
  def current_params(defaults, read) when is_map(defaults) and is_function(read, 2) do
    Map.new(defaults, fn {key, default} ->
      case read.(:pparams, key) do
        nil -> {key, default}
        enacted -> {key, enacted}
      end
    end)
  end
end
