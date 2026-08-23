defmodule Cardamom.Ledger.Praos.ContinuityTest do
  @moduledoc """
  Tier-1 header CONTINUITY (Praos): a header must link to its parent — the hash chain plus the
  block-number and slot ordering. Pure over `(header, parent)`; the parent is resolved from the
  store by the handler and injected here.

  Rules:
    * prev_hash = nil ⇒ genesis / era-start: continuity is vacuous (no parent). But a nil prev
      with block_number > 0 is impossible — a violation (only the first block has no parent).
    * parent = :not_found ⇒ SKIP (out-of-order arrival is normal; the forest resolves it later —
      never a false reject, same discipline as the conservation oracle's unresolved input).
    * parent present ⇒ block_number = parent + 1 AND slot strictly greater than the parent's.

  The header's `hash` is already blake2b of its received bytes, and we look the parent up BY that
  `prev_hash`, so "prev_hash = hash(parent)" holds by construction of the lookup — continuity here
  is the NUMBER + SLOT ordering the hash link alone doesn't enforce.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Praos.Continuity

  defp hdr(fields), do: Enum.into(fields, %{prev_hash: <<0::256>>, block_number: 1, slot: 100})
  defp parent(fields), do: Enum.into(fields, %{block_no: 0, slot: 50})

  test "a well-linked header (n = parent+1, slot > parent) passes" do
    assert Continuity.check(hdr(block_number: 5, slot: 200), parent(block_no: 4, slot: 150)) == :ok
  end

  test "genesis (prev_hash nil, block_number 0) passes vacuously" do
    assert Continuity.check(hdr(prev_hash: nil, block_number: 0, slot: 0), :not_found) == :ok
  end

  test "nil prev_hash with block_number > 0 is a VIOLATION (only genesis has no parent)" do
    assert {:invalid, {:orphan_nonzero_block, _}} =
             Continuity.check(hdr(prev_hash: nil, block_number: 7, slot: 0), :not_found)
  end

  test "parent not yet stored ⇒ SKIP (out-of-order arrival, not a reject)" do
    assert {:skip, :parent_not_found} =
             Continuity.check(hdr(prev_hash: <<9::256>>, block_number: 5), :not_found)
  end

  test "wrong block number (not parent+1) is a violation" do
    assert {:invalid, {:block_number, %{expected: 5, got: 6}}} =
             Continuity.check(hdr(block_number: 6, slot: 200), parent(block_no: 4, slot: 150))
  end

  test "non-increasing slot is a violation (equal or earlier than parent)" do
    assert {:invalid, {:slot_not_increasing, _}} =
             Continuity.check(hdr(block_number: 5, slot: 150), parent(block_no: 4, slot: 150))

    assert {:invalid, {:slot_not_increasing, _}} =
             Continuity.check(hdr(block_number: 5, slot: 149), parent(block_no: 4, slot: 150))
  end

  test "MC/DC: number right but slot wrong, and slot right but number wrong, each caught alone" do
    # number ok, slot bad
    assert {:invalid, {:slot_not_increasing, _}} =
             Continuity.check(hdr(block_number: 5, slot: 10), parent(block_no: 4, slot: 150))
    # slot ok, number bad
    assert {:invalid, {:block_number, _}} =
             Continuity.check(hdr(block_number: 9, slot: 200), parent(block_no: 4, slot: 150))
  end
end
