defmodule Cardamom.Ledger.TxValidation do
  @moduledoc """
  Per-transaction validation as an INDEPENDENT, context-injected step — the same rules for a
  tx in a block and a tx in the mempool ([[project_tx_validation_independence]]). Extracted
  from `Cardamom.Ledger.BlockHandler`'s inline loop so nothing here reaches into ChainStore or
  a process: state arrives via the injected `read` fun, era/params via `ctx`.

  `run(tx, read, ctx)` returns `{ops, results}` for one decoded tx, in spec order — PRE-CERT
  withdrawals (checked + zeroed) then the tx's certs (Certs.lagda.md:632-633):

    * `ops`     — invertible ledger-delta ops (`{:set,…}`/`{:add,…}`), journalled by the caller,
    * `results` — `{rule, outcome, opts}` check tuples, each stamped with the tx's `:txid`, fed
      to `Cardamom.Ledger.Verdict`.

  `read` is `(domain, key) -> value | nil`. To see this tx's own earlier ops (and earlier txs'),
  the caller passes a `Cardamom.Ledger.Delta.read_through/2` overlay over the returned ops.

  `ctx` is `%{protocol_major: pos_integer, pp: deposits}`:
    * `protocol_major` ERA-GATES rules that changed at a hard fork — keyed off PROTOCOL MAJOR,
      the correct version axis ([[reference_cardano_version_axes]]); e.g. the withdrawal
      vote-delegation precondition is Conway-only (major ≥ 9), so on Babbage data it must not
      fire (this fixed a real latent false-reject),
    * `pp` is the protocol deposits map for cert deposit/refund terms.

  Three policies wrap the SAME results downstream: chain block → assertion/stop-and-fix,
  replay → halt, mempool → falsifiable prediction.
  """

  alias Cardamom.Ledger.{Delta, WithdrawalEffects, CertEffects}
  alias Cardamom.Ledger.Conway.Cert

  @doc """
  Validate one decoded tx against `read`+`ctx`, returning `{ops, results}` (spec order).
  `base_read` semantics: pass a plain store reader; this threads a read-through overlay so a
  later op in THIS tx sees an earlier one (same-tx visibility — invertibility correctness).
  """
  def run(tx, base_read, ctx) when is_function(base_read, 2) and is_map(ctx) do
    txid = Map.get(tx, :txid)
    major = Map.fetch!(ctx, :protocol_major)
    pp = Map.fetch!(ctx, :pp)

    # PRE-CERT: withdrawals first, against the base state.
    read0 = Delta.read_through([], base_read)

    {w_ops, w_results} =
      WithdrawalEffects.effects(Map.get(tx, :withdrawals, []), read0, major)

    # Then this tx's certs, each over the running overlay of the ops so far.
    {ops, cert_results} =
      tx
      |> Map.get(:certs)
      |> Cert.decode_all()
      |> Enum.reduce({w_ops, []}, fn cert, {ops, cres} ->
        read = Delta.read_through(ops, base_read)
        {ops ++ CertEffects.effects(cert, read, pp), cres}
      end)

    {ops, stamp(w_results ++ cert_results, txid)}
  end

  # Every check result carries the tx it came from, for verdict attribution.
  defp stamp(results, txid) do
    Enum.map(results, fn {rule, outcome, opts} -> {rule, outcome, Keyword.put(opts, :txid, txid)} end)
  end
end
