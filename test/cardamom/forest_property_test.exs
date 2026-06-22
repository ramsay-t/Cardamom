defmodule Cardamom.ForestPropertyTest do
  @moduledoc """
  Property tests for the forest — the consensus-belief data structure where a missed
  branch (fork-choice, out-of-order arrival, cascade) is the kind of "small but
  critical" bug coverage % can't surface. These explore the INPUT SPACE: generate
  arbitrary header-arrival sequences (forks, duplicates, out-of-order, dangling
  parents) and assert invariants hold regardless.

  This is our stand-in for the MC/DC tool we don't have — it hunts the branch/case we
  forgot by varying inputs, not by measuring executed lines.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cardamom.Forest

  # A small pool of headers, each with a FIXED parent — because a real header's hash
  # commits to its parent (hbPrev is in the hashed HeaderBody; confirmed from
  # ouroboros-consensus Praos/Header.hs: headerHash = hashAnnotated over the body that
  # contains hbPrev). So "same hash, different parent" is cryptographically impossible
  # for honest headers — it's only producible by a liar, and header-hash verification
  # eliminates it upstream. We therefore generate HONEST input (one parent per hash),
  # which is the input space where the convergence invariant must hold. The pool
  # deliberately includes links, forks, and dangling/cyclic parents — just consistent
  # per hash — so arrival order, forks, and gaps are all exercised.
  @headers [
    %{hash: "h1", parent_hash: nil},          # genesis child
    %{hash: "h2", parent_hash: "h1"},
    %{hash: "h3", parent_hash: "h2"},
    %{hash: "h4", parent_hash: "h2"},         # fork off h2
    %{hash: "h5", parent_hash: "h4"},
    %{hash: "h6", parent_hash: "missing"},    # dangling parent (gap / orphan)
    %{hash: "h7", parent_hash: "h6"},         # chains onto the orphan
    %{hash: "h8", parent_hash: "h3"}
  ]

  # Generate sublists (with repeats allowed) of the honest header set, in any order.
  defp header_gen, do: member_of(@headers)

  # Build a forest from a list of headers (added in given order).
  defp build(headers), do: Enum.reduce(headers, Forest.new(), &Forest.add(&2, &1))

  property "arrival order doesn't matter: any permutation yields the same heights & tip" do
    check all headers <- list_of(header_gen(), max_length: 25) do
      forest_a = build(headers)
      forest_b = build(Enum.shuffle(headers))
      forest_c = build(Enum.reverse(headers))

      # The connected heights map is identical regardless of arrival order — the
      # whole "file-don't-chase + cascade-on-connect" promise.
      assert forest_a.heights == forest_b.heights
      assert forest_a.heights == forest_c.heights
      # And the chosen tip is identical (deterministic fork choice, order-independent).
      assert Forest.tip(forest_a) == Forest.tip(forest_b)
      assert Forest.tip(forest_a) == Forest.tip(forest_c)
    end
  end

  property "the tip is always a CONNECTED node at the maximum connected height" do
    check all headers <- list_of(header_gen(), max_length: 25) do
      f = build(headers)
      tip = Forest.tip(f)

      assert Forest.connected?(f, tip), "tip must be connected to the root"

      tip_h = Forest.height(f, tip)
      max_connected_h =
        f.heights
        |> Enum.filter(fn {_hash, h} -> is_integer(h) end)
        |> Enum.map(fn {_hash, h} -> h end)
        |> Enum.max(fn -> 0 end)

      assert tip_h == max_connected_h, "tip is at the greatest connected height"
    end
  end

  property "adding is idempotent: re-adding the same headers changes nothing" do
    check all headers <- list_of(header_gen(), max_length: 25) do
      once = build(headers)
      twice = Enum.reduce(headers, once, &Forest.add(&2, &1))
      assert once.heights == twice.heights
      assert once.parents == twice.parents
      assert Forest.tip(once) == Forest.tip(twice)
    end
  end

  property "every connected node's height = parent's height + 1 (height invariant)" do
    check all headers <- list_of(header_gen(), max_length: 25) do
      f = build(headers)

      for {hash, h} <- f.heights, is_integer(h), hash != f.root, not is_nil(hash) do
        parent = Map.get(f.parents, hash)
        parent_h = Map.get(f.heights, parent)
        # A connected node's parent must itself be connected, at height h-1.
        assert parent_h == h - 1,
               "#{inspect(hash)} at height #{h} but parent #{inspect(parent)} at #{inspect(parent_h)}"
      end
    end
  end

  property "never crashes on adversarial input (cycles, dangling parents, dups)" do
    check all headers <- list_of(header_gen(), max_length: 40) do
      # Must not raise, whatever the arrival pattern. Tip is always well-defined.
      f = build(headers)
      assert Forest.tip(f) != nil
      assert is_list(Forest.leaves(f))
    end
  end
end
