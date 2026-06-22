defmodule Cardamom.Ledger.Conway.HeaderTest do
  @moduledoc """
  Unit tests for the Conway header decoder, against synthetic-but-CDDL-shaped
  headers (build the structure, CBOR-encode, decode, assert every field). The
  decoder isn't wired into the live path yet (Connection uses the hash-only Stub),
  so these tests are what prove it BEFORE real header bytes arrive — and they'll
  be complemented by a real-Preview-bytes fixture once captured.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Conway.Header

  # Build real-shaped header bytes via HeaderBuilder (single source of the correct
  # 15-field Praos layout — no second hand-built shape to drift). The :prev_hash
  # default here is a random 32-byte hash unless overridden.
  defp build_header(opts \\ []) do
    opts =
      case Keyword.get(opts, :prev_hash, :random) do
        :random -> Keyword.put(opts, :prev_hash, :crypto.strong_rand_bytes(32))
        _ -> opts
      end

    Cardamom.Ledger.Conway.HeaderBuilder.build(opts).raw
  end

  test "decodes all header_body fields" do
    raw = build_header(block_number: 4_400_600, slot: 115_289_152, block_body_size: 1234)
    assert {:ok, h} = Header.decode(raw)

    assert h.block_number == 4_400_600
    assert h.slot == 115_289_152
    assert h.block_body_size == 1234
    assert byte_size(h.issuer_vkey) == 32
    assert byte_size(h.vrf_vkey) == 32
    assert byte_size(h.block_body_hash) == 32
    assert byte_size(h.prev_hash) == 32
    assert h.protocol_version == {10, 0}
    assert %{hot_vkey: hv, sequence_number: _, kes_period: _, sigma: sig} = h.operational_cert
    assert byte_size(hv) == 32 and byte_size(sig) == 64
  end

  test "the hash is the REAL blake2b-256 of the raw bytes" do
    raw = build_header()
    assert {:ok, h} = Header.decode(raw)
    assert h.hash == Cardamom.Crypto.blake2b_256(raw)
    assert h.hash_hex == Base.encode16(h.hash, case: :lower)
    assert h.raw_size == byte_size(raw)
  end

  test "prev_hash = nil (genesis / first block of era) decodes as nil, not a crash" do
    raw = build_header(prev_hash: nil)
    assert {:ok, h} = Header.decode(raw)
    assert h.prev_hash == nil
  end

  test "decoding is deterministic for identical bytes" do
    raw = build_header()
    assert {:ok, a} = Header.decode(raw)
    assert {:ok, b} = Header.decode(raw)
    assert a.hash == b.hash and a.slot == b.slot
  end

  describe "strict — reject, never coerce" do
    test "non-binary input errors" do
      assert {:error, :not_binary} = Header.decode(:not_bytes)
    end

    test "well-formed CBOR that isn't a header errors (not coerced)" do
      assert {:error, _} = Header.decode(CBOR.encode([1, 2, 3]))
    end

    test "a header_body with the wrong arity errors" do
      short_body = [1, 2, 3]
      raw = CBOR.encode([short_body, %CBOR.Tag{tag: :bytes, value: <<0::448*8>>}])
      assert {:error, {:bad_header_body, _}} = Header.decode(raw)
    end

    test "never raises on arbitrary bytes" do
      for _ <- 1..100 do
        bytes = :crypto.strong_rand_bytes(:rand.uniform(40))
        assert match?({:ok, _}, Header.decode(bytes)) or match?({:error, _}, Header.decode(bytes))
      end
    end
  end

  # Broken headers — each malformed in ONE specific way. Now that we decode the
  # structure, we must REJECT broken structure, not silently embed an error as a
  # field value. (Errors-as-field-values would be exactly the kind of plausible-
  # looking-garbage we've banned.)
  describe "broken headers — malformed components are rejected" do
    # A valid 15-field header_body we then corrupt one position of.
    #  0 block_no 1 slot 2 prev 3 vk 4 vrfVk 5 vrfRes 6 vrfRes2 7 bodySize
    #  8 bodyHash 9 oc_hotvkey 10 oc_n 11 oc_kesper 12 oc_sigma 13 protMaj 14 protMin
    defp body_with(replace) do
      b = fn n -> %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(n)} end

      base = [
        100, 200, b.(32), b.(32), b.(32),
        [b.(64), b.(80)], [b.(64), b.(80)],
        50, b.(32),
        b.(32), 0, 0, b.(64),
        10, 0
      ]

      body = Enum.reduce(replace, base, fn {idx, val}, acc -> List.replace_at(acc, idx, val) end)
      CBOR.encode([body, %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(448)}])
    end

    test "a non-integer opcert sequence number (field 10) is rejected by the guard" do
      raw = body_with(%{10 => "not-an-int"})
      assert {:error, {:bad_header_body, _}} = Header.decode(raw)
    end

    test "a non-integer protocol major (field 13) is rejected" do
      raw = body_with(%{13 => "soon"})
      assert {:error, {:bad_header_body, _}} = Header.decode(raw)
    end

    test "a non-integer block_number is rejected (guard, not coerced)" do
      raw = body_with(%{0 => "not-a-number"})
      assert {:error, _} = Header.decode(raw)
    end

    test "a non-integer slot is rejected" do
      raw = body_with(%{1 => "soon"})
      assert {:error, _} = Header.decode(raw)
    end

    test "a header_body that is too short is rejected" do
      raw = CBOR.encode([[1, 2, 3], %CBOR.Tag{tag: :bytes, value: <<0::448*8>>}])
      assert {:error, {:bad_header_body, _}} = Header.decode(raw)
    end

    test "a header with no KES signature element is rejected" do
      body = [100, 200, nil, %CBOR.Tag{tag: :bytes, value: <<0::256>>}]
      assert {:error, _} = Header.decode(CBOR.encode([body]))
    end
  end

  # Hashing: right now hashes are for IDENTITY + LINKAGE, not verification (we
  # have no protocol step that VERIFIES against a hash yet — that comes with body
  # validation). These pin the identity/linkage properties.
  describe "header hash (identity + linkage, not verification)" do
    test "two headers built with the same bytes share a hash; different bytes differ" do
      raw_a = build_header(slot: 1)
      raw_b = build_header(slot: 1)
      {:ok, ha} = Header.decode(raw_a)
      {:ok, hb} = Header.decode(raw_b)
      {:ok, ha2} = Header.decode(raw_a)

      assert ha.hash == ha2.hash, "same bytes -> same hash"
      refute ha.hash == hb.hash, "different random fields -> different hash"
    end

    test "linkage: a child's prev_hash can equal a parent's hash (chain links)" do
      parent_raw = build_header(block_number: 1, slot: 1)
      {:ok, parent} = Header.decode(parent_raw)

      # Build a child whose prev_hash is the parent's REAL hash.
      child_raw = build_header(block_number: 2, slot: 2, prev_hash: parent.hash)
      {:ok, child} = Header.decode(child_raw)

      assert child.prev_hash == parent.hash
    end
  end
end
