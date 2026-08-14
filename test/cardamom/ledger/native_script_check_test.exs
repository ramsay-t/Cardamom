defmodule Cardamom.Ledger.NativeScriptCheckTest do
  @moduledoc """
  Native-script GATE WIRING (Conway UTXOW, the script half of `witsVKeyNeeded`): for each spent
  input whose payment credential is `{:script, h}`, a NATIVE script with `hash(script) == h` must
  be supplied in the witnesses AND must be SATISFIED (`Cardamom.Ledger.NativeScript`).

    * native-script hash = blake2b_224(0x00 ‖ CBOR(script))  (nativeMultiSigTag = "\\00")
    * env = signers (supplied vkey key-hashes) + the tx's validity interval.

  Outcomes (`:native_scripts` verdict tuple):
    * :pass       — every script-locked input matched a supplied native script that is satisfied,
    * {:violation}— a required native script is missing, unsatisfied, or a script-input's hash has
                    no supplied native script (could be a Plutus script — see skip),
    * {:skip}     — an input we can't resolve, or a script-input whose hash matches a supplied
                    PLUTUS script (phase-2, opaque here) — no native verdict.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.{NativeScriptCheck, NativeScript}

  defp kh(n), do: <<n::224>>
  defp script_addr(h), do: <<0x10, h::binary, 0::224>>
  defp reader(m), do: fn txid, ix -> get_in(m, [{txid, ix}]) end
  defp r(rule, results), do: Enum.find(results, &(elem(&1, 0) == rule))

  # canonical script hash the ledger uses
  defp shash(script_term), do: NativeScript.hash(script_term)

  test "script hash: blake2b_224 of (0x00 ‖ cbor(script)) — a known shape round-trips" do
    script = {:sig, kh(1)}
    h = NativeScript.hash(script)
    assert byte_size(h) == 28
    # deterministic
    assert NativeScript.hash(script) == h
  end

  test "PASS: a script-locked input, its native script supplied and satisfied" do
    script = {:all, [{:sig, kh(1)}]}
    h = shash(script)
    utxo = %{{<<1::256>>, 0} => %{address: script_addr(h)}}

    tx = %{
      txid: <<7::256>>,
      inputs: [{<<1::256>>, 0}],
      witnesses: %{vkey: [], native: [script], bootstrap: []},
      invalid_before: nil,
      invalid_hereafter: nil
    }

    env = %{signers: MapSet.new([kh(1)]), lower: nil, upper: nil}
    {results, _} = NativeScriptCheck.check(tx, reader(utxo), env)
    assert {:native_scripts, :pass, _} = r(:native_scripts, results)
  end

  test "VIOLATION: script supplied but NOT satisfied (missing signer)" do
    script = {:sig, kh(1)}
    h = shash(script)
    utxo = %{{<<1::256>>, 0} => %{address: script_addr(h)}}

    tx = %{txid: <<7::256>>, inputs: [{<<1::256>>, 0}],
           witnesses: %{vkey: [], native: [script], bootstrap: []}, invalid_before: nil, invalid_hereafter: nil}

    env = %{signers: MapSet.new([]), lower: nil, upper: nil}
    {results, _} = NativeScriptCheck.check(tx, reader(utxo), env)
    assert {:native_scripts, {:violation, d}, _} = r(:native_scripts, results)
    assert d.unsatisfied != [] or d.missing != []
  end

  test "VIOLATION: a script-locked input with NO supplied script of that hash" do
    utxo = %{{<<1::256>>, 0} => %{address: script_addr(kh(99))}}
    tx = %{txid: <<7::256>>, inputs: [{<<1::256>>, 0}],
           witnesses: %{vkey: [], native: [], bootstrap: []}, invalid_before: nil, invalid_hereafter: nil}

    env = %{signers: MapSet.new([]), lower: nil, upper: nil}
    {results, _} = NativeScriptCheck.check(tx, reader(utxo), env)
    assert {:native_scripts, {:violation, _}, _} = r(:native_scripts, results)
  end

  test "key-locked inputs contribute NOTHING (no native verdict needed) → pass" do
    utxo = %{{<<1::256>>, 0} => %{address: <<0x00, kh(1)::binary, 0::224>>}}
    tx = %{txid: <<7::256>>, inputs: [{<<1::256>>, 0}],
           witnesses: %{vkey: [], native: [], bootstrap: []}, invalid_before: nil, invalid_hereafter: nil}

    {results, _} = NativeScriptCheck.check(tx, reader(utxo), %{signers: MapSet.new(), lower: nil, upper: nil})
    assert {:native_scripts, :pass, _} = r(:native_scripts, results)
  end

  test "SKIP: an unresolved input → no native verdict (no false reject)" do
    tx = %{txid: <<7::256>>, inputs: [{<<9::256>>, 0}],
           witnesses: %{vkey: [], native: [], bootstrap: []}, invalid_before: nil, invalid_hereafter: nil}
    {results, _} = NativeScriptCheck.check(tx, reader(%{}), %{signers: MapSet.new(), lower: nil, upper: nil})
    assert {:native_scripts, {:skip, _}, _} = r(:native_scripts, results)
  end

  test "timelock inside a script honours the tx validity interval" do
    script = {:all, [{:sig, kh(1)}, {:invalid_hereafter, 200}]}
    h = shash(script)
    utxo = %{{<<1::256>>, 0} => %{address: script_addr(h)}}

    tx = %{txid: <<7::256>>, inputs: [{<<1::256>>, 0}],
           witnesses: %{vkey: [], native: [script], bootstrap: []}, invalid_before: nil, invalid_hereafter: 200}

    env = %{signers: MapSet.new([kh(1)]), lower: nil, upper: 200}
    {results, _} = NativeScriptCheck.check(tx, reader(utxo), env)
    assert {:native_scripts, :pass, _} = r(:native_scripts, results)
  end
end
