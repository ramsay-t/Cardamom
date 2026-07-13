defmodule Cardamom.Ledger.BlocksMadeTest do
  @moduledoc """
  BlocksMade (the `b` of createRUpd — Rewards.lagda.md:421-422): per-pool block counts for one
  epoch, derived by walking prev_hash links back from a known block. FORK-SAFETY is the point
  under test: the headers table retains fork headers, and they must NOT be counted.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{ChainStore, Crypto}

  @epoch_length 100

  defp vkey(n), do: <<n::256>>
  defp hash(n), do: <<n::256>>

  defp put_header(n, prev_n, slot, issuer_n) do
    {:ok, _} =
      ChainStore.put_header(%{
        hash: hash(n),
        prev_hash: prev_n && hash(prev_n),
        slot: slot,
        block_no: n,
        issuer_vkey: vkey(issuer_n),
        raw: <<n::256>>
      })
  end

  test "counts only chain headers in the epoch, keyed by blake2b-224 of the issuer vkey" do
    # epoch 1 = slots 100..199. Chain: 1(90) ← 2(110,A) ← 3(150,B) ← 4(160,A) ← 5(210)
    put_header(1, nil, 90, 9)
    put_header(2, 1, 110, 1)
    put_header(3, 2, 150, 2)
    put_header(4, 3, 160, 1)
    put_header(5, 4, 210, 9)

    # FORK at slot 155 by issuer 3, NOT on the chain from header 5 — must not be counted.
    put_header(99, 2, 155, 3)

    bm = ChainStore.blocks_made(1, hash(5), @epoch_length)

    assert bm == %{
             Crypto.blake2b_224(vkey(1)) => 2,
             Crypto.blake2b_224(vkey(2)) => 1
           }
  end

  test "MC/DC: an empty epoch (no chain headers in range) is an empty map" do
    put_header(1, nil, 90, 9)
    put_header(2, 1, 210, 9)
    assert ChainStore.blocks_made(1, hash(2), @epoch_length) == %{}
  end

  test "MC/DC: the walk stops cleanly at the genesis edge (prev not in the table)" do
    # the whole chain sits inside the epoch; the first header's prev doesn't exist
    put_header(2, 1, 110, 1)
    put_header(3, 2, 120, 1)
    assert ChainStore.blocks_made(1, hash(3), @epoch_length) ==
             %{Crypto.blake2b_224(vkey(1)) => 2}
  end
end
