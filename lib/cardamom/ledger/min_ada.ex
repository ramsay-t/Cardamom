defmodule Cardamom.Ledger.MinAda do
  @moduledoc """
  The minimum RETAINED value a UTxO must hold — a SWAPPABLE POLICY behind a seam, deliberately
  NOT baked into the rule that uses it. This is a floor the ADA STAYS LOCKED IN the output (not a
  fee, not consumed); the ledger checks `coinTxOut < getMinCoinTxOut pp txOut` (Shelley Utxo.hs).
  The min-ADA system is expected to change on-chain in a way that may alter not just the
  coefficient but the RULE'S SHAPE (e.g. permitting a small UTxO value with the surplus directed
  to an account, rather than a per-UTxO integer minimum). Isolating the whole computation here
  means a future rule is a NEW module implementing this behaviour + a config swap — no change to
  `Cardamom.Ledger.EconomicRules`, which only asks "what min coin does this output require?".

  NAMES MATCH THE HASKELL SOURCE deliberately (fidelity over prettier names, so cross-referencing
  the ledger is unambiguous): the behaviour method is `get_min_coin_tx_out` (class method
  `getMinCoinTxOut`, cardano-ledger Core/TxOut); the Babbage impl is `babbage_min_utxo_value`
  (`babbageMinUTxOValue`); the fixed 160 term is `constant_overhead` (`constantOverhead`).

  `get_min_coin_tx_out(output, params) :: non_neg_integer() | :unknown`. `:unknown` = can't be
  computed from the params we have (the caller SKIPS rather than guessing). NOTE: a future
  account-redirection policy won't fit a pure integer answer — when we get there this behaviour
  grows a richer return (e.g. `{:min, n}` / `{:redirect, small, surplus_target}`) and
  `EconomicRules` branches on it; the SEAM is here so that change is contained.
  """

  @type params :: map()
  @callback get_min_coin_tx_out(output :: map(), params()) :: non_neg_integer() | :unknown

  @doc "The active min-UTxO policy module (app-env swappable; defaults to the Babbage form)."
  def policy, do: Application.get_env(:cardamom, :min_ada_policy, __MODULE__.Babbage)

  @doc "Minimum coin `output` must hold under the active policy, or `:unknown` (getMinCoinTxOut)."
  def get_min_coin_tx_out(output, params), do: policy().get_min_coin_tx_out(output, params)

  defmodule Babbage do
    @moduledoc """
    Babbage/Conway min-UTxO (cardano-ledger `babbageMinUTxOValue`, Babbage/TxOut.hs):

        minUTxO = coinsPerUTxOByte · (constantOverhead + |serialised output|)

    `constantOverhead` is the ledger's own name (TxOut.hs:688): a fixed approximation of the
    MEMORY cost every UTxO carries beyond its serialised bytes — the `TxIn` plus a Map entry,
    `160 = 20 words · 8 bytes`. It is NOT a serialised size and NOT a protocol parameter; it's a
    constant in the ledger's fee model. Both it and the coin-per-byte rate come from `params`
    (`:constant_overhead`, `:coins_per_utxo_byte`) — nothing is inline in the formula, so a rate
    change (param update) OR a constant/formula change (a future era) is config, not a code edit.
    `:unknown` when the rate is absent (Preview: an enacted param we don't yet track).
    """
    @behaviour Cardamom.Ledger.MinAda

    # Default for the ledger's `constantOverhead` (160 = 20 words × 8 bytes), used when params
    # don't carry one; overridable via params (:constant_overhead). A fallback, not a magic
    # number inline in the rule.
    @default_constant_overhead 160

    # `babbageMinUTxOValue` (cardano-ledger Babbage/TxOut.hs) — the getMinCoinTxOut impl for
    # Babbage/Conway.
    @impl true
    def get_min_coin_tx_out(output, params) do
      case Map.get(params, :coins_per_utxo_byte) do
        cpb when is_integer(cpb) ->
          overhead = Map.get(params, :constant_overhead, @default_constant_overhead)
          cpb * (overhead + output_size(output))

        _ ->
          :unknown
      end
    end

    defp output_size(%{raw: raw}) when is_binary(raw), do: byte_size(raw)
    defp output_size(_), do: 0
  end
end
