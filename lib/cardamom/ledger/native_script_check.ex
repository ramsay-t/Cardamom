defmodule Cardamom.Ledger.NativeScriptCheck do
  @moduledoc """
  Native-script GATE WIRING (Conway UTXOW, the script half of witness validation) — completes
  `Cardamom.Ledger.WitnessCheck`'s vkey half. For each spent input whose payment credential is a
  SCRIPT `{:script, h}`, a native script with `NativeScript.hash(script) == h` must be supplied in
  the witnesses AND must be SATISFIED against the tx's signers + validity interval.

  One `:native_scripts` verdict per tx:
    * `:pass`        — every script-locked input matched a supplied, satisfied native script (and
      key-locked inputs need nothing here),
    * `{:violation}` — a required native script is missing, or supplied-but-unsatisfied,
    * `{:skip}`      — an input we can't resolve, OR a script-input whose hash matches no supplied
      NATIVE script (it may be a Plutus script — phase-2, opaque; not a native-script failure).

  `env` is the `Cardamom.Ledger.NativeScript` environment (`%{signers, lower, upper}`) — signers =
  the tx's supplied vkey key-hashes, lower/upper = the tx's validity interval — built by the caller
  (`TxValidation`) once and shared with the vkey checks. Pure; `read` resolves an input's TXO.
  """

  alias Cardamom.Ledger.{NativeScript, Address}

  @doc "The `:native_scripts` result for one tx. Returns `{[result], :ok}`."
  def check(tx, read, env) when is_map(tx) and is_function(read, 2) and is_map(env) do
    supplied = index_by_hash(Map.get(tx, :witnesses, %{})[:native] || [])
    plutus = plutus_hashes(Map.get(tx, :witnesses, %{}))
    inputs = Map.get(tx, :inputs, []) ++ Map.get(tx, :collateral_inputs, [])

    # Per script-locked input, classify into one of: satisfied (ok) / unsatisfied / missing (no
    # supplied script at all) / plutus (its hash is a supplied Plutus script → skip, phase-2) /
    # unresolved (can't read the input → skip).
    acc =
      Enum.reduce(inputs, %{unsat: [], missing: [], plutus: false, unresolved: false}, fn {txid, ix}, acc ->
        case read.(txid, ix) do
          %{address: addr} when is_binary(addr) ->
            case Address.payment_credential(addr) do
              {:script, h} -> classify(h, supplied, plutus, env, acc)
              _ -> acc
            end

          _ ->
            %{acc | unresolved: true}
        end
      end)

    {[{:native_scripts, verdict(acc), [txid: Map.get(tx, :txid)]}], :ok}
  end

  defp classify(h, supplied, plutus, env, acc) do
    cond do
      script = Map.get(supplied, h) ->
        if NativeScript.satisfied?(script, env),
          do: acc,
          else: %{acc | unsat: [hex(h) | acc.unsat]}

      MapSet.member?(plutus, h) ->
        %{acc | plutus: true}

      true ->
        %{acc | missing: [hex(h) | acc.missing]}
    end
  end

  defp verdict(%{unsat: unsat, missing: missing, plutus: plutus, unresolved: unresolved}) do
    cond do
      unsat != [] or missing != [] -> {:violation, %{unsatisfied: unsat, missing: missing}}
      unresolved -> {:skip, :unresolved_input}
      plutus -> {:skip, :plutus_script_input}
      true -> :pass
    end
  end

  # Plutus script hashes are blake2b_224(tag ‖ script) with a per-language tag (v1=0x01, v2=0x02,
  # v3=0x03). We keep plutus scripts RAW (%CBOR.Tag bytes), so hash the tagged raw bytes.
  defp plutus_hashes(w) do
    for {tag, key} <- [{0x01, :plutus_v1}, {0x02, :plutus_v2}, {0x03, :plutus_v3}],
        %CBOR.Tag{tag: :bytes, value: raw} <- Map.get(w, key, []),
        into: MapSet.new(),
        do: Cardamom.Crypto.blake2b_224(<<tag, raw::binary>>)
  end

  # Map each supplied native script by its hash for O(1) lookup by an input's script credential.
  defp index_by_hash(scripts) do
    Map.new(scripts, fn s -> {NativeScript.hash(s), s} end)
  end

  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)
end
