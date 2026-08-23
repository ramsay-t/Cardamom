defmodule Cardamom.Ledger.Conway.WitnessTest do
  @moduledoc """
  Decoding `transaction_witness_set` (conway.cddl) — the surface phase-1 witness rules
  (vkey-signature verification, witness coverage, native-script evaluation) all sit on.
  Kept as INERT DATA (Harvard boundary): scripts/data decode to structural terms we
  evaluate/hash, never to anything callable.

    transaction_witness_set =
      { ? 0 : [* vkeywitness]        ; [vkey(32), signature(64)]
      , ? 1 : [* native_script]
      , ? 2 : [* bootstrap_witness]
      , ? 3 : [* plutus_v1_script]   ; kept raw (phase-2, opaque)
      , ? 4 : [* plutus_data]        ; kept raw
      , ? 5 : redeemers              ; kept raw
      , ? 6 : [* plutus_v2_script]   ; raw
      , ? 7 : [* plutus_v3_script] } ; raw

  native_script (recursive):
      [0, keyhash28] | [1, [scripts]] | [2, [scripts]] | [3, n, [scripts]]
      | [4, slot]  (invalid_before)  | [5, slot] (invalid_hereafter)
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Conway.Witness

  defp bytes(b), do: %CBOR.Tag{tag: :bytes, value: b}
  defp set(list), do: %CBOR.Tag{tag: 258, value: list}

  test "vkey witnesses: [vkey, sig] pairs → {vkey, sig} tuples (both bare array and set-tagged)" do
    vk = <<1::256>>
    sig = <<2::512>>

    w = Witness.decode(%{0 => [[bytes(vk), bytes(sig)]]})
    assert w.vkey == [{vk, sig}]

    # Conway wraps these in set tag 258 — must handle both
    w2 = Witness.decode(%{0 => set([[bytes(vk), bytes(sig)]])})
    assert w2.vkey == [{vk, sig}]
  end

  test "native scripts decode recursively to a tagged structural tree" do
    kh = <<9::224>>
    # all-of [ sig(kh), invalid_hereafter(500) ]
    script = [1, [[0, bytes(kh)], [5, 500]]]
    w = Witness.decode(%{1 => [script]})

    assert w.native == [
             {:all, [{:sig, kh}, {:invalid_hereafter, 500}]}
           ]
  end

  test "native scripts: every leaf/branch shape" do
    kh = <<7::224>>

    assert Witness.decode(%{1 => [[0, bytes(kh)]]}).native == [{:sig, kh}]
    assert Witness.decode(%{1 => [[2, []]]}).native == [{:any, []}]
    assert Witness.decode(%{1 => [[3, 2, [[0, bytes(kh)]]]]}).native == [{:n_of_k, 2, [{:sig, kh}]}]
    assert Witness.decode(%{1 => [[4, 100]]}).native == [{:invalid_before, 100}]
  end

  test "bootstrap (Byron) witnesses decode to a struct-ish map" do
    w = Witness.decode(%{2 => [[bytes(<<1::256>>), bytes(<<2::512>>), bytes(<<3::256>>), bytes(<<0>>)]]})
    assert [%{vkey: <<1::256>>, signature: <<2::512>>, chain_code: <<3::256>>}] = w.bootstrap
  end

  test "plutus scripts / data / redeemers are kept RAW (phase-2 is opaque here)" do
    w = Witness.decode(%{3 => [bytes(<<0xAB>>)], 4 => [42], 5 => %{}, 6 => [bytes(<<0xCD>>)], 7 => [bytes(<<0xEF>>)]})
    assert w.plutus_v1 == [bytes(<<0xAB>>)]
    assert w.plutus_data == [42]
    assert w.redeemers == %{}
    assert w.plutus_v2 == [bytes(<<0xCD>>)]
    assert w.plutus_v3 == [bytes(<<0xEF>>)]
  end

  test "an empty / absent witness set decodes to all-empty, never crashes" do
    w = Witness.decode(%{})
    assert w.vkey == [] and w.native == [] and w.bootstrap == []
    assert Witness.decode(nil) == Witness.decode(%{})
  end

  test "malformed entries are dropped defensively, not raised" do
    w = Witness.decode(%{0 => [[bytes(<<1::256>>)]], 1 => [[99, :junk]]})
    assert w.vkey == []
    assert w.native == [{:unknown, [99, :junk]}]
  end

  # MC/DC per clause: the defensive drop/fallthrough arms.
  test "vkey witness with wrong-sized vkey or sig is dropped (not kept malformed)" do
    assert Witness.decode(%{0 => [[bytes(<<1::128>>), bytes(<<2::512>>)]]}).vkey == []
    assert Witness.decode(%{0 => [[bytes(<<1::256>>), bytes(<<2::256>>)]]}).vkey == []
  end

  test "a bootstrap witness with the wrong arity is dropped" do
    assert Witness.decode(%{2 => [[bytes(<<1::256>>)]]}).bootstrap == []
  end

  test "a non-list / non-set value under a key decodes to empty (items fallthrough)" do
    assert Witness.decode(%{0 => :not_a_list, 1 => 42}) |> Map.take([:vkey, :native]) ==
             %{vkey: [], native: []}
  end

  test "native n_of_k with a non-integer n falls to {:unknown, _} (guard miss)" do
    assert Witness.decode(%{1 => [[3, :not_int, []]]}).native == [{:unknown, [3, :not_int, []]}]
  end

  test "decode_block_witnesses on non-block bytes returns {:error, _}, never raises" do
    assert {:error, _} = Witness.decode_block_witnesses(<<0xFF, 1, 2, 3>>)
  end

  test "a vkey witness with a non-bytes-tag value still decodes (unbytes fallthrough), then drops on size" do
    # raw binary (not %CBOR.Tag{:bytes}) — unbytes passes it through; 32/64 sizes still enforced
    assert Witness.decode(%{0 => [[<<1::256>>, <<2::512>>]]}).vkey == [{<<1::256>>, <<2::512>>}]
  end

  test "REAL fixture: the witness set of a real Preview tx-bearing block decodes" do
    raw =
      "test/fixtures/preview_block_with_tx.hex"
      |> File.read!()
      |> String.trim()
      |> Base.decode16!(case: :mixed)

    assert {:ok, sets} = Witness.decode_block_witnesses(raw)
    assert is_list(sets) and sets != []

    # This real block's tx carries a Byron-address BOOTSTRAP witness (key 2), not a vkey
    # witness — decode it and check the byte shapes (vkey 32, sig 64, chain_code 32). Every
    # witness the block does carry must decode to well-formed bytes.
    assert Enum.any?(sets, fn w -> w.bootstrap != [] or w.vkey != [] end),
           "the signed tx has at least one witness"

    for w <- sets do
      for {vk, sig} <- w.vkey, do: assert(byte_size(vk) == 32 and byte_size(sig) == 64)

      for b <- w.bootstrap do
        assert byte_size(b.vkey) == 32 and byte_size(b.signature) == 64 and byte_size(b.chain_code) == 32
      end
    end
  end
end
