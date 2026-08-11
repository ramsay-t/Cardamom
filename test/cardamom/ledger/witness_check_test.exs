defmodule Cardamom.Ledger.WitnessCheckTest do
  @moduledoc """
  Phase-1 witness rules (UTXOW), the first to USE the decoded witness set:

    * SIGNATURE VALIDITY — every vkey witness `{vkey, sig}` is a real Ed25519 signature over the
      txid (the tx body hash; Ed25519 hashes internally so we verify over the 32-byte txid).
    * COVERAGE (`witsVKeyNeeded`) — every KEY-hash the tx needs a signature from has a matching
      vkey witness present. The needed set = payment key-hashes of spent (and collateral) inputs
      + reward-account key-hashes of withdrawals + required_signers. SCRIPT credentials are NOT
      in the vkey-needed set (native/plutus witnesses satisfy those).

  Real crypto throughout (Ed25519 via :crypto) — vectors are self-generated keypairs signing the
  real txid, so a broken check can't pass. Results are verdict tuples; era-independent here.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.WitnessCheck

  # a real Ed25519 keypair; key hash = blake2b_224(vkey), the Cardano credential hash
  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp keyhash(vk), do: Cardamom.Crypto.blake2b_224(vk)
  defp sign(msg, sk), do: :crypto.sign(:eddsa, :none, msg, [sk, :ed25519])

  # base address (type 0, network 0): payment KEY hash then a stake key hash
  defp base_addr(pay_kh, stake_kh \\ <<0::224>>), do: <<0x00, pay_kh::binary, stake_kh::binary>>

  defp reader(utxo), do: fn txid, ix -> Map.get(utxo, {txid, ix}) end

  defp result(rule, results), do: Enum.find(results, &(elem(&1, 0) == rule))

  test "a correctly-signed single-input tx: signature valid AND coverage satisfied" do
    {vk, sk} = keypair()
    txid = <<7::256>>
    addr = base_addr(keyhash(vk))
    utxo = %{{<<1::256>>, 0} => %{address: addr}}

    tx = %{
      txid: txid,
      inputs: [{<<1::256>>, 0}],
      witnesses: %{vkey: [{vk, sign(txid, sk)}], native: [], bootstrap: []}
    }

    {results, _} = WitnessCheck.check(tx, reader(utxo))
    assert {:vkey_signatures, :pass, _} = result(:vkey_signatures, results)
    assert {:witness_coverage, :pass, _} = result(:witness_coverage, results)
  end

  test "SIGNATURE VIOLATION: a witness whose sig doesn't verify over the txid" do
    {vk, _sk} = keypair()
    {_vk2, sk2} = keypair()
    txid = <<7::256>>

    tx = %{
      txid: txid,
      inputs: [],
      # vk with a signature made by a DIFFERENT key → invalid
      witnesses: %{vkey: [{vk, sign(txid, sk2)}], native: [], bootstrap: []}
    }

    {results, _} = WitnessCheck.check(tx, reader(%{}))
    assert {:vkey_signatures, {:violation, _}, _} = result(:vkey_signatures, results)
  end

  test "COVERAGE VIOLATION: a spent input needs a key that never signed" do
    {vk, _sk} = keypair()
    # the input demands vk's key-hash, but NO witness is supplied
    addr = base_addr(keyhash(vk))
    utxo = %{{<<1::256>>, 0} => %{address: addr}}

    tx = %{txid: <<7::256>>, inputs: [{<<1::256>>, 0}], witnesses: %{vkey: [], native: [], bootstrap: []}}

    {results, _} = WitnessCheck.check(tx, reader(utxo))
    assert {:witness_coverage, {:violation, detail}, _} = result(:witness_coverage, results)
    assert detail.missing != []
  end

  test "SCRIPT payment credential does NOT demand a vkey (coverage passes with no witness)" do
    # type-1 base address = payment SCRIPT; a script input needs a script witness, not a vkey
    script_addr = <<0x10, 9::224, 0::224>>
    utxo = %{{<<1::256>>, 0} => %{address: script_addr}}

    tx = %{txid: <<7::256>>, inputs: [{<<1::256>>, 0}], witnesses: %{vkey: [], native: [], bootstrap: []}}

    {results, _} = WitnessCheck.check(tx, reader(utxo))
    assert {:witness_coverage, :pass, _} = result(:witness_coverage, results)
  end

  test "withdrawals contribute their reward-account KEY hash to the needed set" do
    {vk, sk} = keypair()
    txid = <<7::256>>
    reward_addr = <<0xE0, keyhash(vk)::binary>>

    tx = %{
      txid: txid,
      inputs: [],
      withdrawals: [{reward_addr, 1_000}],
      witnesses: %{vkey: [{vk, sign(txid, sk)}], native: [], bootstrap: []}
    }

    {results, _} = WitnessCheck.check(tx, reader(%{}))
    assert {:witness_coverage, :pass, _} = result(:witness_coverage, results)
  end

  test "an unresolved input can't contribute its key-hash → coverage SKIPS (no false reject)" do
    tx = %{txid: <<7::256>>, inputs: [{<<9::256>>, 0}], witnesses: %{vkey: [], native: [], bootstrap: []}}
    {results, _} = WitnessCheck.check(tx, reader(%{}))
    assert {:witness_coverage, {:skip, _}, _} = result(:witness_coverage, results)
  end

  test "results are stamped with the txid" do
    tx = %{txid: <<42::256>>, inputs: [], witnesses: %{vkey: [], native: [], bootstrap: []}}
    {results, _} = WitnessCheck.check(tx, reader(%{}))
    assert Enum.all?(results, fn {_r, _o, opts} -> Keyword.get(opts, :txid) == <<42::256>> end)
  end
end
