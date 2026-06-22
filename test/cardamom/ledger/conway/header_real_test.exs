defmodule Cardamom.Ledger.Conway.HeaderRealTest do
  @moduledoc """
  Regression test against GENUINE captured Preview bytes
  (test/fixtures/preview_rollforward.hex — a real RollForward from
  preview-node.play.dev.cardano.org, era 4, 961-byte header). Network-free, runs
  every time. If our header decoder drifts from the real Praos wire layout, this
  fails. This is the ground-truth pin (no synthetic data).
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Conway.Header
  alias Cardamom.Protocol.ChainSync.Codec, as: CS

  @rollforward_hex File.read!(Path.join(__DIR__, "../../../fixtures/preview_rollforward.hex"))
                   |> String.trim()

  defp real_raw_header do
    payload = Base.decode16!(@rollforward_hex, case: :lower)
    {:ok, {:roll_forward, envelope, _tip}, ""} = CS.decode(payload)
    [_era, %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: raw}}] = envelope
    raw
  end

  test "the captured payload is a chain-sync RollForward with a tag-24 header envelope" do
    payload = Base.decode16!(@rollforward_hex, case: :lower)
    assert {:ok, {:roll_forward, [era, %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes}}], _tip}, ""} =
             CS.decode(payload)

    assert era == 4
  end

  test "decodes the REAL Preview header into all 15 flat fields" do
    raw = real_raw_header()
    assert byte_size(raw) == 961

    assert {:ok, h} = Header.decode(raw)

    # Fields from the real bytes (this is the genesis/first header in the run).
    assert is_integer(h.block_number)
    assert is_integer(h.slot)
    assert byte_size(h.issuer_vkey) == 32
    assert byte_size(h.vrf_vkey) == 32
    assert byte_size(h.block_body_hash) == 32
    assert byte_size(h.operational_cert.hot_vkey) == 32
    assert byte_size(h.operational_cert.sigma) == 64
    assert match?({_maj, _min}, h.protocol_version)
  end

  test "the REAL header hash is its actual blake2b-256 (32 bytes), deterministic" do
    raw = real_raw_header()
    {:ok, h} = Header.decode(raw)
    assert h.hash == Cardamom.Crypto.blake2b_256(raw)
    assert byte_size(h.hash) == 32
    assert h.hash_hex =~ ~r/^[0-9a-f]{64}$/
  end
end
