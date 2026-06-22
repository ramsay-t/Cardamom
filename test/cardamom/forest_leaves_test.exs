defmodule Cardamom.ForestLeavesTest do
  @moduledoc """
  `Forest.leaves/1` = the open tips of the belief, the candidate resume points.
  The header table stores everything verdict-free; leaves are the CONNECTED open
  tips only, best-first. Critical for resume: at shutdown there may be SEVERAL open
  tips (forks), and we offer all of them to FindIntersect.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Forest

  test "a linear chain has exactly one leaf: the tip" do
    f =
      Forest.new()
      |> Forest.add(%{hash: "a", parent_hash: nil})
      |> Forest.add(%{hash: "b", parent_hash: "a"})
      |> Forest.add(%{hash: "c", parent_hash: "b"})

    assert Forest.leaves(f) == ["c"]
  end

  test "a fork yields multiple leaves, ordered best-first (greatest height)" do
    # a <- b <- c (h3), and a <- b <- d <- e (h4). Two open tips: e (h4), c (h3).
    f =
      Forest.new()
      |> Forest.add(%{hash: "a", parent_hash: nil})
      |> Forest.add(%{hash: "b", parent_hash: "a"})
      |> Forest.add(%{hash: "c", parent_hash: "b"})
      |> Forest.add(%{hash: "d", parent_hash: "b"})
      |> Forest.add(%{hash: "e", parent_hash: "d"})

    # e is height 4 (a,b,d,e), c is height 3 — best-first puts e before c.
    assert Forest.leaves(f) == ["e", "c"]
  end

  test "orphans (unconnected) are NOT leaves — the store keeps them, the forest doesn't offer them" do
    f =
      Forest.new()
      |> Forest.add(%{hash: "a", parent_hash: nil})
      # parent never arrived → floating, height nil
      |> Forest.add(%{hash: "orphan", parent_hash: "missing"})

    assert Forest.leaves(f) == ["a"]
    refute "orphan" in Forest.leaves(f)
  end

  test "a node with a connected child is not a leaf (the child is the open tip)" do
    f =
      Forest.new()
      |> Forest.add(%{hash: "a", parent_hash: nil})
      |> Forest.add(%{hash: "b", parent_hash: "a"})

    leaves = Forest.leaves(f)
    assert leaves == ["b"]
    refute "a" in leaves
  end

  test "a fresh forest (root only) has no resume leaves" do
    assert Forest.leaves(Forest.new()) == []
  end
end
