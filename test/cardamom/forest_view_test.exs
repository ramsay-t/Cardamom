defmodule Cardamom.ForestViewTest do
  @moduledoc """
  `Forest.view/2` is the pure data behind the live UI panel. It must (a) return the
  spine from the tip backwards, newest-first, bounded by depth; (b) flag fork rows
  (sibling children of a spine node's parent) so the structure's whole reason for
  existing — divergent candidate chains — is visible; (c) count global forks and
  floating (unconnected, height-nil) nodes for the summary badges.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Forest

  # Build a linear chain h1..hN onto genesis (prev_hash nil connects at height 1).
  defp linear(n) do
    Enum.reduce(1..n, {Forest.new(), nil}, fn i, {f, prev} ->
      hash = "h#{i}"
      {Forest.add(f, %{hash: hash, parent_hash: prev}), hash}
    end)
    |> elem(0)
  end

  test "view returns the spine newest-first, bounded by depth" do
    f = linear(10)
    v = Forest.view(f, 4)

    assert v.tip == "h10"
    assert v.tip_height == 10
    # 4 spine rows, no forks → exactly 4 rows, tip first.
    assert length(v.rows) == 4
    assert hd(v.rows) == %{height: 10, hash: "h10", fork?: false}
    assert Enum.map(v.rows, & &1.hash) == ["h10", "h9", "h8", "h7"]
  end

  test "a fork is surfaced as a fork? row alongside the spine" do
    # h1 <- h2 <- h3 (tip), plus a sibling h2' also off h1.
    f =
      Forest.new()
      |> Forest.add(%{hash: "h1", parent_hash: nil})
      |> Forest.add(%{hash: "h2", parent_hash: "h1"})
      |> Forest.add(%{hash: "h3", parent_hash: "h2"})
      |> Forest.add(%{hash: "h2b", parent_hash: "h1"})

    v = Forest.view(f, 12)

    assert v.forks == 1, "h1 has two children → one fork point"
    fork_hashes = v.rows |> Enum.filter(& &1.fork?) |> Enum.map(& &1.hash)
    assert "h2b" in fork_hashes, "the sibling chain head must appear as a fork row"
  end

  test "floating (unconnected) nodes are counted but not on the connected spine" do
    # h1 connects; an orphan whose parent never arrived stays height nil (floating).
    f =
      Forest.new()
      |> Forest.add(%{hash: "h1", parent_hash: nil})
      |> Forest.add(%{hash: "orphan", parent_hash: "missing-parent"})

    v = Forest.view(f, 12)

    assert v.floating == 1
    assert Forest.height(f, "orphan") == nil
  end
end
