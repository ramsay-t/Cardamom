defmodule Cardamom.Ledger.StubTest do
  use ExUnit.Case, async: true

  alias Cardamom.Ledger

  # The network layer is GENERIC over the header (chain-sync is parameterised over
  # header/point/tip). So we are too: the Ledger behaviour interprets opaque raw
  # header bytes; the network layer never knows Conway header structure. The Stub
  # gives us the era-independent part — the header HASH (its identity / our
  # advancing position) — and leaves field decoding (slot, prev_hash, ...) to a
  # real era-specific Ledger impl later.

  @ledger {Cardamom.Ledger.Stub, nil}

  test "header_point returns the REAL blake2b-256 of the raw header bytes" do
    raw = "some-opaque-header-bytes"
    {:ok, point} = Ledger.header_point(@ledger, raw)

    # The point hash IS the genuine Cardano hash (matches Crypto.blake2b_256),
    # so it can be compared to a real node's hash — not a look-alike.
    assert point.hash == Cardamom.Crypto.blake2b_256(raw)
    assert byte_size(point.hash) == 32
    # slot field decoding is deferred to a real (era-specific) ledger impl
    assert point.slot == :unknown
  end

  test "different header bytes -> different hash (so a cursor visibly advances)" do
    {:ok, p1} = Ledger.header_point(@ledger, "block-1")
    {:ok, p2} = Ledger.header_point(@ledger, "block-2")
    refute p1.hash == p2.hash
  end

  test "hashes are hex-encoded for logging convenience" do
    {:ok, p} = Ledger.header_point(@ledger, "x")
    assert p.hash_hex =~ ~r/^[0-9a-f]{64}$/
  end

  test "non-binary input is rejected (not coerced)" do
    assert {:error, :not_raw_header_bytes} = Ledger.header_point(@ledger, [1, 2, 3])
  end
end
