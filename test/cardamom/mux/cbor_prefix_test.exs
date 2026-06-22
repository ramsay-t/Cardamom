defmodule Cardamom.Mux.CborPrefixTest do
  @moduledoc """
  Structural CBOR-prefix detection: is a buffer a whole CBOR item, a valid-but-short
  PREFIX of one (truncated → wait for more), or genuinely malformed? Decided by walking
  the CBOR heads (which declare lengths), NOT by sniffing CBOR.decode error atoms (which
  don't reliably distinguish "short" from "corrupt"). Shared by the mini-protocol codecs
  so a message split across SDU boundaries is carried over, not mistaken for corruption.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Mux.Cbor

  defp enc(term), do: CBOR.encode(term)

  test "a whole simple value is complete" do
    assert Cbor.complete?(enc(42))
    assert Cbor.complete?(enc(-7))
    assert Cbor.complete?(enc("hello"))
    assert Cbor.complete?(enc([1, 2, 3]))
  end

  test "every truncation of a real-shaped CBOR item is INcomplete (a prefix)" do
    # A block-fetch-shaped message: [4, #6.24(bytes)] with a chunky byte string.
    term = [4, %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(800)}}]
    full = enc(term)

    for n <- 1..(byte_size(full) - 1) do
      refute Cbor.complete?(binary_part(full, 0, n)),
             "truncation at #{n}/#{byte_size(full)} must be incomplete (a prefix)"
    end

    assert Cbor.complete?(full)
  end

  test "an array whose declared elements aren't all present yet is incomplete" do
    # [2, header, tip] with header truncated mid-byte-string.
    full = enc([2, %CBOR.Tag{tag: :bytes, value: :crypto.strong_rand_bytes(500)}, [9, 9]])
    assert Cbor.complete?(full)
    refute Cbor.complete?(binary_part(full, 0, 20))
  end

  test "a map (e.g. a tip encoded as a map) is handled, not treated as malformed" do
    full = enc(%{1 => 2, 3 => [4, 5]})
    assert Cbor.complete?(full)
    refute Cbor.complete?(binary_part(full, 0, 2))
  end

  test "the empty buffer is incomplete (nothing decoded yet)" do
    refute Cbor.complete?(<<>>)
  end

  test "trailing bytes after a whole item: still complete (the first item IS present)" do
    # complete?/1 asks 'is at least one whole item present?' — extra bytes (the next
    # glued message) don't make it incomplete.
    assert Cbor.complete?(enc(1) <> enc(2) <> enc(3))
  end

  describe "indefinite-length items (break-terminated)" do
    # CBOR major-type heads with additional-info 31 = indefinite length, ended by the
    # 0xFF break stop-code. We hand-encode these (CBOR.encode emits definite lengths).
    test "an indefinite-length array is complete only once the break arrives" do
      # 0x9F = array(*), two small ints, 0xFF = break.
      whole = <<0x9F, 0x01, 0x02, 0xFF>>
      assert Cbor.complete?(whole)
      refute Cbor.complete?(<<0x9F, 0x01, 0x02>>), "no break yet → incomplete"
      refute Cbor.complete?(<<0x9F>>)
    end

    test "an indefinite-length byte string (chunked) is complete at the break" do
      # 0x5F = bytes(*), one 2-byte chunk (0x42 ab), break.
      whole = <<0x5F, 0x42, 0xAA, 0xBB, 0xFF>>
      assert Cbor.complete?(whole)
      refute Cbor.complete?(<<0x5F, 0x42, 0xAA>>), "chunk not finished → incomplete"
    end
  end
end
