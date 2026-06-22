defmodule Cardamom.ForestTest do
  @moduledoc """
  The candidate forest as a PURE data structure (no process), tested with toy
  (hash, parent_hash) pairs — deterministic, no network, no decode. Pins the
  design we agonised over: file-don't-chase (gaps held, coalesce on arrival),
  forks (two children of one parent), rollback (move the tip), tip selection
  (longest chain from a known root). Trust-everything: nothing is pruned yet.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Forest

  # A forest seeded with a known root hash (the point we anchor on; genesis-ish).
  defp seeded, do: Forest.new("root")

  # add a header given as {hash, parent_hash}
  defp add(f, hash, parent), do: Forest.add(f, %{hash: hash, parent_hash: parent})

  describe "linear chain" do
    test "a chain built on the root advances the tip" do
      f =
        seeded()
        |> add("a", "root")
        |> add("b", "a")
        |> add("c", "b")

      assert Forest.tip(f) == "c"
      assert Forest.height(f, "c") == 3
    end

    test "an unknown header (no root, no parent present) is held, not linked" do
      f = add(seeded(), "orphan", "missing-parent")
      # tip is still root — orphan isn't connected to a known root
      assert Forest.tip(f) == "root"
      assert Forest.connected?(f, "orphan") == false
    end
  end

  describe "gaps — file-don't-chase, coalesce on arrival" do
    test "a header whose parent arrives LATER links up when the parent comes" do
      # B (parent A) arrives before A.
      f =
        seeded()
        |> add("b", "a")
        |> add("a", "root")

      # Once A arrives connecting to root, B coalesces and the tip is B.
      assert Forest.connected?(f, "a")
      assert Forest.connected?(f, "b")
      assert Forest.tip(f) == "b"
    end

    test "a multi-block gap fills in any order" do
      f =
        seeded()
        |> add("d", "c")
        |> add("c", "b")
        |> add("b", "a")
        |> add("a", "root")

      assert Forest.tip(f) == "d"
      assert Forest.height(f, "d") == 4
    end

    test "a still-unfilled gap leaves the fragment disconnected" do
      f =
        seeded()
        |> add("c", "b")
        |> add("b", "a")

      # a's parent (root link via a) never arrived, so nothing connects
      assert Forest.connected?(f, "b") == false
      assert Forest.connected?(f, "c") == false
      assert Forest.tip(f) == "root"
    end
  end

  describe "forks" do
    test "two children of the same parent are both tracked" do
      f =
        seeded()
        |> add("a", "root")
        |> add("b1", "a")
        |> add("b2", "a")

      assert Forest.children(f, "a") |> Enum.sort() == ["b1", "b2"]
    end

    test "tip follows the longest branch" do
      f =
        seeded()
        |> add("a", "root")
        |> add("b1", "a")
        |> add("b2", "a")
        |> add("c2", "b2")

      # branch via b2->c2 is longer
      assert Forest.tip(f) == "c2"
    end
  end

  describe "rollback — move the tip pointer" do
    test "rollback sets the tip to an earlier point" do
      f =
        seeded()
        |> add("a", "root")
        |> add("b", "a")
        |> add("c", "b")

      assert Forest.tip(f) == "c"
      f = Forest.rollback(f, "a")
      assert Forest.tip(f) == "a"
    end

    test "rollback to an unknown point is rejected (tip unchanged)" do
      f = seeded() |> add("a", "root")
      assert Forest.tip(f) == "a"
      f2 = Forest.rollback(f, "nope")
      assert Forest.tip(f2) == "a"
    end
  end

  describe "idempotence / dedup" do
    test "adding the same header twice is harmless" do
      f = seeded() |> add("a", "root") |> add("a", "root")
      assert Forest.tip(f) == "a"
      assert Forest.height(f, "a") == 1
    end
  end

  # The incremental design: height is stored, nil until connected to root, and
  # filled by a forward cascade only when the connecting block arrives. These pin
  # that behaviour (the thing that must stay O(1)-per-add, not O(N) recompute).
  describe "height is nil until connected, then cascade-filled" do
    test "a floating fragment (base's parent missing) has nil height throughout" do
      f =
        seeded()
        |> add("a", "missing")
        |> add("b", "a")
        |> add("c", "b")

      assert Forest.height(f, "a") == nil
      assert Forest.height(f, "b") == nil
      assert Forest.height(f, "c") == nil
      refute Forest.connected?(f, "c")
    end

    test "when the connecting block arrives, the whole fragment gets correct heights" do
      f =
        seeded()
        # build a floating 3-chain whose base 'a' is parented on 'gap'
        |> add("a", "gap")
        |> add("b", "a")
        |> add("c", "b")

      assert Forest.height(f, "c") == nil

      # the missing block arrives, connecting 'gap' to root
      f = add(f, "gap", "root")

      # cascade fills: gap=1, a=2, b=3, c=4 — and the tip jumps to c
      assert Forest.height(f, "gap") == 1
      assert Forest.height(f, "a") == 2
      assert Forest.height(f, "b") == 3
      assert Forest.height(f, "c") == 4
      assert Forest.tip(f) == "c"
    end

    test "adding onto a floating fragment keeps it nil (no premature height)" do
      f = seeded() |> add("a", "missing") |> add("b", "a")
      assert Forest.height(f, "b") == nil
      # base still unconnected; tip stays at root
      assert Forest.tip(f) == "root"
    end
  end

  # Real chains are rooted at genesis, whose headers carry prev_hash: nil. A
  # genesis-anchored forest must connect those directly (the root-seeding fix).
  describe "genesis root (nil prev_hash)" do
    test "a header with prev_hash nil connects to the genesis root at height 1" do
      f = Forest.new() |> Forest.add(%{hash: "g1", parent_hash: nil})
      assert Forest.height(f, "g1") == 1
      assert Forest.connected?(f, "g1")
      assert Forest.tip(f) == "g1"
    end

    test "a real-shaped chain (genesis nil, then linked) advances the tip" do
      f =
        Forest.new()
        |> Forest.add(%{hash: "g1", parent_hash: nil})
        |> Forest.add(%{hash: "b2", parent_hash: "g1"})
        |> Forest.add(%{hash: "b3", parent_hash: "b2"})

      assert Forest.tip(f) == "b3"
      assert Forest.height(f, "b3") == 3
    end
  end
end
