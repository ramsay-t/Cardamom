defmodule Cardamom.Ledger.TxHandler do
  @moduledoc """
  The per-TRANSACTION unit of work. A block is a lot of these; an Endorser Block (Leios) will be
  the SAME lot of these — the container is just a source of txs, and processing each tx is
  identical whether it arrived in a block body or an EB.

  It takes a tx as EITHER raw CBOR bytes (a standalone tx body, as TxSubmission delivers, or one
  span out of a container) OR an already-decoded tx map (what `Conway.Tx.txs_in/1` yields, so a
  container that already decoded its bodies doesn't re-decode). `coerce/1` normalises both to the
  decoded map.

  THE PHASE BOUNDARY is the one thing this module exists to protect. The Agda block-level rule
  `newUtxo = (utxo ∣ ins ᶜ) ∪ outs` is computed over the WHOLE container: ALL of its outputs must
  exist BEFORE ANY of its spends resolve, so a tx can spend an earlier tx's output in the same
  container (intra-container output→input chains). Therefore the handler exposes the two phases
  as SEPARATE calls — `create_outputs/2` (phase 1) and `apply_spends/2` (phase 2) — and the
  container driver runs phase 1 across every tx before phase 2 across every tx. Within a phase the
  txs are independent (order-free, parallelisable); only the boundary is ordered. `process/2` runs
  both phases for ONE standalone tx (no container, so no cross-tx chaining to honour) — used for a
  lone tx, not inside a block/EB loop.

  Storage effects (insert_txo / mark_spent) live in `Cardamom.ChainStore`, which owns the
  single-writer connection; this module is the LEDGER-shaped wrapper that says WHAT a tx does to
  the UTxO set (valid → inputs/outputs; invalid/phase-2-fail → collateral only), per the Conway
  UTxO rule. It does not decide concurrency — the container driver does (see ChainStore.process_
  block). CBOR decoding is pure and CPU-bound, so a container CAN fan `coerce/1` across schedulers
  and then run the two write-phases serially through the single writer (parse-parallel/write-serial).
  """

  alias Cardamom.Ledger.Conway.Tx
  alias Cardamom.ChainStore

  @type tx_input :: {binary(), non_neg_integer()}

  @doc """
  Normalise a tx given as raw CBOR bytes OR an already-decoded tx map to the decoded map.
  Bytes are decoded as a STANDALONE body (validity defaults true — a bare tx carries no block
  verdict; the chain decides validity only when it lands in a block). A map is returned as-is.
  """
  @spec coerce(binary() | map()) :: {:ok, map()} | {:error, term()}
  def coerce(%{txid: _} = tx), do: {:ok, tx}
  def coerce(bytes) when is_binary(bytes), do: Tx.decode_tx(bytes)
  def coerce(_), do: {:error, :not_a_tx}

  @doc """
  PHASE 1 for one tx: create its outputs as unspent TXOs. Valid tx → its normal outputs.
  Invalid (phase-2-fail) tx → NOT its normal outputs, ONLY its collateral_return, at index
  `length(outputs)` (the declared normal outputs consume index space even though they aren't
  created — SPEC: Babbage Collateral.hs `txIxFromIntegral (length outputs)`). `slot` is stamped as
  created_slot for rollback. Accepts bytes or a decoded map.
  """
  @spec create_outputs(binary() | map(), integer() | nil) :: :ok | {:error, term()}
  def create_outputs(tx, slot) do
    with {:ok, decoded} <- coerce(tx) do
      do_create_outputs(decoded, slot)
      :ok
    end
  end

  defp do_create_outputs(%{valid: true, txid: txid, outputs: outputs}, slot) do
    outputs
    |> Enum.with_index()
    |> Enum.each(fn {out, ix} -> ChainStore.insert_txo(txid, ix, out, slot) end)
  end

  defp do_create_outputs(%{valid: false, txid: txid, collateral_return: ret, outputs: outputs}, slot) do
    if ret, do: ChainStore.insert_txo(txid, length(outputs), ret, slot)
    :ok
  end

  @doc """
  PHASE 2 for one tx: apply its spends. Valid tx (Agda ~488) → its normal inputs are spent,
  spent_how :tx_input. Invalid tx (~503) → ONLY collateral is consumed, spent_how :collateral;
  normal inputs are NOT spent. `slot` stamped as spent_slot for rollback.

  RETURNS the list of inputs that could NOT be applied because their target TXO isn't stored yet
  ([] = all applied). A missing target is NOT an error for a confirmed container — the input must
  live in a container we haven't ingested yet (cross-container / out-of-order backfill); the
  DRIVER treats a non-empty return as "deferred" and leaves the container unprocessed for the
  reconciler to retry. Accepts bytes or a decoded map.
  """
  @spec apply_spends(binary() | map(), integer() | nil) :: {:ok, [tx_input()]} | {:error, term()}
  def apply_spends(tx, slot) do
    with {:ok, decoded} <- coerce(tx) do
      {:ok, do_apply_spends(decoded, slot)}
    end
  end

  defp do_apply_spends(%{valid: true, txid: txid, inputs: inputs}, slot),
    do: spend_each(inputs, txid, :tx_input, slot)

  defp do_apply_spends(%{valid: false, txid: txid, collateral_inputs: collat}, slot),
    do: spend_each(collat, txid, :collateral, slot)

  defp spend_each(inputs, txid, how, slot) do
    Enum.flat_map(inputs, fn {src_txid, src_ix} ->
      case ChainStore.mark_spent(src_txid, src_ix, txid, how, slot) do
        :ok -> []
        {:error, :no_target} -> [{src_txid, src_ix}]
      end
    end)
  end

  @doc """
  Run BOTH phases for ONE STANDALONE tx (no container). Returns `:ok` if fully applied or
  `{:deferred, unresolved_inputs}` if a cross-container spend awaits its producer. Use INSIDE a
  block/EB loop only via the separate `create_outputs`/`apply_spends` phases so the whole
  container's outputs land before any spend — calling `process/2` per tx in a container would
  break intra-container output→input chaining.
  """
  @spec process(binary() | map(), integer() | nil) :: :ok | {:deferred, [tx_input()]} | {:error, term()}
  def process(tx, slot \\ nil) do
    with {:ok, decoded} <- coerce(tx),
         :ok <- create_outputs(decoded, slot),
         {:ok, deferred} <- apply_spends(decoded, slot) do
      if deferred == [], do: :ok, else: {:deferred, deferred}
    end
  end
end
