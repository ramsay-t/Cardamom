defmodule Cardamom.Ledger.Praos.VrfOutputTest do
  @moduledoc """
  VRF cert OUTPUT-CONSISTENCY at the header gate (Praos.Validation.verify_vrf_output): the header's
  stated VRF output must be the one its proof derives to. Header-only (no epoch nonce / stake) —
  the stateless half of VRF checking; the full leader-election threshold check layers on later when
  η + σ exist. Proven against a real Preview header.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Praos.{Header, Validation}

  defp real_header do
    raw = "test/fixtures/preview_rollforward_praos.hex" |> File.read!() |> String.trim() |> Base.decode16!(case: :mixed)
    {:ok, h} = Header.decode(raw)
    h
  end

  defp tag(b), do: %CBOR.Tag{tag: :bytes, value: b}

  test "a real Preview header's VRF output derives from its proof (:ok)" do
    assert Validation.verify_vrf_output(real_header()) == :ok
  end

  test "a tampered VRF OUTPUT (right proof) → :vrf_output_mismatch" do
    h = real_header()
    [_out, proof] = h.vrf_result
    bad = %{h | vrf_result: [tag(<<0::512>>), proof]}
    assert {:invalid, :vrf_output_mismatch} = Validation.verify_vrf_output(bad)
  end

  test "a tampered VRF PROOF (right stated output) → mismatch (proof derives a different output)" do
    h = real_header()
    [out, %CBOR.Tag{value: proof}] = h.vrf_result
    <<first, rest::binary>> = proof
    bad = %{h | vrf_result: [out, tag(<<Bitwise.bxor(first, 1), rest::binary>>)]}
    assert {:invalid, :vrf_output_mismatch} = Validation.verify_vrf_output(bad)
  end

  test "wrong-sized output / proof → size violation, never raises" do
    h = real_header()
    [_out, proof] = h.vrf_result
    assert {:invalid, {:vrf_output_size, _}} = Validation.verify_vrf_output(%{h | vrf_result: [tag(<<0::256>>), proof]})
    assert {:invalid, {:vrf_proof_size, _}} = Validation.verify_vrf_output(%{h | vrf_result: [tag(<<0::512>>), tag(<<0::320>>)]})
  end

  test "a header with no VRF cert (Byron/other) is not asserted (:ok)" do
    assert Validation.verify_vrf_output(%{block_number: 0}) == :ok
  end
end
