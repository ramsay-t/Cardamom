defmodule Cardamom.Ledger.NativeScriptTest do
  @moduledoc """
  Native-script (timelock) EVALUATION — full validation of a real script class with zero Plutus.
  Semantics (Shelley multisig + Allegra timelocks; the decoded tree from
  `Cardamom.Ledger.Conway.Witness`):

    * {:sig, kh}              — kh ∈ signers (the tx's supplied vkey key-hashes)
    * {:all, ss}             — every sub-script satisfied (empty ⇒ true)
    * {:any, ss}             — some sub-script satisfied (empty ⇒ false)
    * {:n_of_k, n, ss}       — at least n of ss satisfied
    * {:invalid_before, s}    — the tx's validity interval starts at/after s (lower ≥ s):
                                the tx can only be accepted from slot s onward.
    * {:invalid_hereafter, s} — the tx's validity interval ends at/before s (upper ≤ s).

  IMPORTANT: timelock leaves are checked against the TX's declared validity interval, NOT the
  block slot directly (the ledger already enforced slot ∈ interval; a timelock says "this script
  is only unlocked for txs whose interval sits the right side of s"). An unbounded interval on
  the relevant side ⇒ the timelock CANNOT be satisfied (you can't prove the bound).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.NativeScript

  defp kh(n), do: <<n::224>>
  # env: the signer set + the tx's validity interval {lower, upper} (nil = unbounded)
  defp env(signers, lower \\ nil, upper \\ nil),
    do: %{signers: MapSet.new(signers), lower: lower, upper: upper}

  test "sig: satisfied iff the key-hash is among the signers" do
    assert NativeScript.satisfied?({:sig, kh(1)}, env([kh(1)]))
    refute NativeScript.satisfied?({:sig, kh(1)}, env([kh(2)]))
  end

  test "all: every sub-script (empty ⇒ true)" do
    assert NativeScript.satisfied?({:all, [{:sig, kh(1)}, {:sig, kh(2)}]}, env([kh(1), kh(2)]))
    refute NativeScript.satisfied?({:all, [{:sig, kh(1)}, {:sig, kh(2)}]}, env([kh(1)]))
    assert NativeScript.satisfied?({:all, []}, env([]))
  end

  test "any: some sub-script (empty ⇒ false)" do
    assert NativeScript.satisfied?({:any, [{:sig, kh(1)}, {:sig, kh(2)}]}, env([kh(2)]))
    refute NativeScript.satisfied?({:any, [{:sig, kh(1)}, {:sig, kh(2)}]}, env([kh(3)]))
    refute NativeScript.satisfied?({:any, []}, env([]))
  end

  test "n_of_k: at least n of the sub-scripts" do
    s = {:n_of_k, 2, [{:sig, kh(1)}, {:sig, kh(2)}, {:sig, kh(3)}]}
    assert NativeScript.satisfied?(s, env([kh(1), kh(3)]))
    refute NativeScript.satisfied?(s, env([kh(1)]))
    assert NativeScript.satisfied?({:n_of_k, 0, []}, env([]))
  end

  test "invalid_before s: tx lower bound must be ≥ s" do
    # interval [100, _): satisfies before(100) and before(50), NOT before(150)
    assert NativeScript.satisfied?({:invalid_before, 100}, env([], 100))
    assert NativeScript.satisfied?({:invalid_before, 50}, env([], 100))
    refute NativeScript.satisfied?({:invalid_before, 150}, env([], 100))
    # unbounded lower ⇒ can't prove ⇒ fail
    refute NativeScript.satisfied?({:invalid_before, 100}, env([], nil))
  end

  test "invalid_hereafter s: tx upper bound must be ≤ s" do
    # interval [_, 200): satisfies hereafter(200) and hereafter(250), NOT hereafter(150)
    assert NativeScript.satisfied?({:invalid_hereafter, 200}, env([], nil, 200))
    assert NativeScript.satisfied?({:invalid_hereafter, 250}, env([], nil, 200))
    refute NativeScript.satisfied?({:invalid_hereafter, 150}, env([], nil, 200))
    refute NativeScript.satisfied?({:invalid_hereafter, 200}, env([], nil, nil))
  end

  test "nested: all[ sig, any[sig,sig], before ]" do
    s = {:all, [{:sig, kh(1)}, {:any, [{:sig, kh(9)}, {:sig, kh(2)}]}, {:invalid_before, 10}]}
    assert NativeScript.satisfied?(s, env([kh(1), kh(2)], 10))
    refute NativeScript.satisfied?(s, env([kh(1)], 10)), "any branch unmet"
    refute NativeScript.satisfied?(s, env([kh(1), kh(2)], 5)), "before(10) unmet at lower=5"
  end

  test "unknown script shape is never satisfied (fail-closed)" do
    refute NativeScript.satisfied?({:unknown, [99]}, env([kh(1)]))
  end

  # ---- hash/1: every encode clause + nested decoded_to_term (MC/DC per clause) ----

  describe "hash/1 covers every script shape (and nesting)" do
    for {label, script} <- [
          sig: {:sig, <<1::224>>},
          all: {:all, [{:sig, <<1::224>>}]},
          any: {:any, [{:sig, <<2::224>>}]},
          n_of_k: {:n_of_k, 1, [{:sig, <<3::224>>}]},
          invalid_before: {:invalid_before, 100},
          invalid_hereafter: {:invalid_hereafter, 200},
          # nesting drives the decoded_to_term arms for each shape
          nested: {:all,
                   [
                     {:sig, <<4::224>>},
                     {:any, [{:n_of_k, 1, [{:sig, <<5::224>>}]}, {:invalid_before, 1}]},
                     {:invalid_hereafter, 9}
                   ]}
        ] do
      test "#{label} hashes to 28 bytes, deterministically" do
        h = NativeScript.hash(unquote(Macro.escape(script)))
        assert byte_size(h) == 28
        assert h == NativeScript.hash(unquote(Macro.escape(script)))
      end
    end

    test "distinct shapes hash distinctly (no accidental collision in the re-encode)" do
      hashes =
        [
          {:sig, <<1::224>>},
          {:all, [{:sig, <<1::224>>}]},
          {:any, [{:sig, <<1::224>>}]},
          {:n_of_k, 1, [{:sig, <<1::224>>}]},
          {:invalid_before, 1},
          {:invalid_hereafter, 1}
        ]
        |> Enum.map(&NativeScript.hash/1)

      assert length(Enum.uniq(hashes)) == length(hashes)
    end
  end

  # ---- satisfied? MC/DC: guard-fail arms fall through to fail-closed ----

  test "MC/DC: n_of_k with a non-integer n / non-list scripts → fail-closed (guard misses)" do
    refute NativeScript.satisfied?({:n_of_k, :not_int, [{:sig, kh(1)}]}, env([kh(1)]))
    refute NativeScript.satisfied?({:n_of_k, 1, :not_a_list}, env([kh(1)]))
  end

  test "MC/DC: sig with a non-binary keyhash → fail-closed" do
    refute NativeScript.satisfied?({:sig, :not_bytes}, env([kh(1)]))
  end

  test "MC/DC: all/any with a non-list body → fail-closed (guard misses)" do
    refute NativeScript.satisfied?({:all, :nope}, env([]))
    refute NativeScript.satisfied?({:any, :nope}, env([]))
  end
end
