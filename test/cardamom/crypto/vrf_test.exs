defmodule Cardamom.Crypto.VRFTest do
  @moduledoc """
  The ECVRF (draft-03, `ECVRF-ED25519-SHA512-Elligator2`) verification suite —
  written BEFORE the implementation (Cardamom.Crypto.VRF is a raising stub), pinned
  to two known-good sources so a wrong implementation cannot pass:

    * TIER 1 — the OFFICIAL vectors: IETF draft-03 §A.4 standards + IOG-generated,
      fetched verbatim from IntersectMBO/cardano-base (the exact bytes the Haskell
      node's libsodium-fork binding is tested against). Agreement = agreement with
      the production implementation. Positive AND per-argument tamper negatives
      (MC/DC: each input falsified alone).
    * TIER 2 — 300 REAL network-accepted proofs from our stored Preview chain:
      stage A (`proof_to_output` — no epoch nonce needed) over every row.
    * TIER 3 — full verify over real headers needs the VRF input
      `blake2b(slot ‖ η)`, i.e. NONCE EVOLUTION — the leader-election oracle.
      Deliberately absent here; lands with η.

  The corpus-integrity tests run NOW (they need no VRF); the crypto tiers are
  tagged `:vrf_pending` (excluded in test_helper until the implementation lands —
  flip by deleting the exclusion, which is the TDD "go red" switch).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Crypto.VRF

  @vectors ~w(vrf_ver03_standard_10 vrf_ver03_standard_11 vrf_ver03_standard_12
              vrf_ver03_generated_1 vrf_ver03_generated_2 vrf_ver03_generated_3
              vrf_ver03_generated_4)

  # ---- fixture parsing ----

  defp load_vector(name) do
    "test/fixtures/vrf/#{name}"
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, ":", parts: 2)
      {String.trim(k), String.trim(v)}
    end)
    |> then(fn m ->
      %{
        name: name,
        pk: hex!(m["pk"]),
        alpha: if(m["alpha"] == "empty", do: <<>>, else: hex!(m["alpha"])),
        pi: hex!(m["pi"]),
        beta: hex!(m["beta"])
      }
    end)
  end

  defp corpus do
    "test/fixtures/vrf/real_headers_praos.tsv"
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [slot, vkey, output, proof] = String.split(line, "\t")
      %{slot: String.to_integer(slot), vkey: hex!(vkey), output: hex!(output), proof: hex!(proof)}
    end)
  end

  defp hex!(s), do: Base.decode16!(s, case: :mixed)

  defp flip_first(<<b, rest::binary>>), do: <<Bitwise.bxor(b, 1), rest::binary>>

  # ---- corpus integrity (runs NOW — no VRF needed; guards the fixtures themselves) ----

  describe "fixture integrity" do
    test "all 7 official vector files parse with draft-03 shapes" do
      for name <- @vectors do
        v = load_vector(name)
        assert byte_size(v.pk) == 32, "#{name}: pk"
        assert byte_size(v.pi) == 80, "#{name}: 80-byte draft-03 proof"
        assert byte_size(v.beta) == 64, "#{name}: 64-byte output"
      end
    end

    test "the standard_10 vector is the IETF draft-03 §A.4 first vector (provenance pin)" do
      v = load_vector("vrf_ver03_standard_10")
      assert v.pk == hex!("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
      assert v.alpha == <<>>
    end

    test "real-header corpus: 300 rows, every field the right shape, slots sane" do
      rows = corpus()
      assert length(rows) == 300

      for r <- rows do
        assert byte_size(r.vkey) == 32
        assert byte_size(r.output) == 64
        assert byte_size(r.proof) == 80
        assert r.slot > 1_000_000
      end
    end
  end

  # ---- TIER 1: official vectors (the known-good implementation, distilled) ----

  describe "official draft-03 vectors" do
    @describetag :vrf_pending

    for name <- @vectors do
      test "#{name}: verify(pk, pi, alpha) yields beta" do
        v = load_vector(unquote(name))
        assert VRF.verify(v.pk, v.pi, v.alpha) == {:ok, v.beta}
      end

      test "#{name}: proof_to_output(pi) yields beta without alpha" do
        v = load_vector(unquote(name))
        assert VRF.proof_to_output(v.pi) == {:ok, v.beta}
      end
    end

    test "MC/DC: tampered PROOF alone → :error (every vector)" do
      for name <- @vectors, v = load_vector(name) do
        assert VRF.verify(v.pk, flip_first(v.pi), v.alpha) == :error, name
      end
    end

    test "MC/DC: tampered ALPHA alone → :error (challenge recomputation catches it)" do
      for name <- @vectors, v = load_vector(name) do
        assert VRF.verify(v.pk, v.pi, v.alpha <> <<0>>) == :error, name
      end
    end

    test "MC/DC: tampered PK alone → :error" do
      for name <- @vectors, v = load_vector(name) do
        assert VRF.verify(flip_first(v.pk), v.pi, v.alpha) == :error, name
      end
    end

    test "MC/DC: malformed sizes → :error, never a raise" do
      v = load_vector("vrf_ver03_standard_10")
      assert VRF.verify(v.pk, binary_part(v.pi, 0, 79), v.alpha) == :error
      assert VRF.verify(binary_part(v.pk, 0, 31), v.pi, v.alpha) == :error
      assert VRF.verify(v.pk, <<>>, v.alpha) == :error
      assert VRF.proof_to_output(<<0::640>>) == :error or match?({:ok, _}, VRF.proof_to_output(<<0::640>>))
    end
  end

  # ---- TIER 2: real chain, stage A (no nonce needed) ----

  describe "real Preview headers, stage A: output derives from proof" do
    @describetag :vrf_pending

    test "all 300 network-accepted proofs: proof_to_output(proof) == stated output" do
      failures =
        for r <- corpus(), VRF.proof_to_output(r.proof) != {:ok, r.output} do
          r.slot
        end

      assert failures == [], "slots with output/proof disagreement: #{inspect(failures)}"
    end

    test "MC/DC: a tampered real proof no longer derives its output" do
      [r | _] = corpus()
      refute VRF.proof_to_output(flip_first(r.proof)) == {:ok, r.output}
    end
  end

  # TIER 3 (deliberately absent): full verify(vk, π, blake2b(slot ‖ η)) over the corpus —
  # requires epoch-nonce evolution. That test IS the leader-election oracle; it lands
  # with η, not here.
end
