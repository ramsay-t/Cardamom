defmodule Cardamom.Forest do
  @moduledoc """
  The candidate-chain forest, a PURE data structure (no process — see
  `Cardamom.Forest.Server`). Belief = a forest of headers over a known root + a
  tip pointer. Headers are added as `%{hash, parent_hash}`.

  ## Incremental design (so `add` stays cheap)

  Each node stores its **height as an integer, or `nil` if not connected to the
  root**. Height is NOT recomputed by walking to root (that was O(N²) and stalled
  the server's mailbox); it's stored and maintained incrementally:

    * Add a node whose parent has a known (non-nil) height → height = parent + 1.
    * Add a node whose parent is absent or itself nil → height `nil` (held;
      file-don't-chase). Adding ONTO a floating fragment is O(1) — we just read
      the parent's nil and store nil; we never walk the fragment.
    * When a missing block finally arrives and *gains* a height, we cascade
      FORWARD through the by-parent index, filling its `nil` descendants. This is
      the only walk, once per node, over just the newly-connected fragment.

  The **tip** (best connected leaf, by greatest height) is tracked incrementally
  on each add/cascade — never by scanning all nodes. A rollback pins an earlier
  tip via `tip_override`.

  Trust-everything: nothing validated, nothing pruned/evicted yet.
  """

  @type hash :: term()
  @type header :: %{hash: hash(), parent_hash: hash() | nil}
  @type t :: %__MODULE__{
          root: hash(),
          parents: %{hash() => hash() | nil},
          heights: %{hash() => non_neg_integer() | nil},
          children: %{hash() => MapSet.t(hash())},
          best: {non_neg_integer(), hash()},
          tip_override: hash() | nil
        }

  defstruct [:root, :parents, :heights, :children, :best, tip_override: nil]

  @doc """
  A forest anchored on the chain origin (genesis). `new/0` uses `:genesis` as the
  root; `new/1` seeds an explicit root (e.g. a resume-from-point intersection).

  Real genesis headers carry `prev_hash: nil`, so we register BOTH the root and
  `nil` as height 0 (nil is an alias for the origin): a `prev_hash: nil` header
  connects to the root at height 1. NOTE the two-nils distinction —
  `heights[nil] = 0` means "nil is the connected origin"; `heights[some_hash] ==
  nil` means "that hash is present but NOT connected". (Ramsay: parent nil, height
  non-nil — exactly this.)
  """
  @spec new() :: t()
  def new(), do: new(:genesis)

  @doc "Like `new/0` but with an explicit `root` (e.g. a resume intersection point)."
  @spec new(hash()) :: t()
  def new(root), do: new_at(root, 0)

  @doc """
  A forest anchored at `root` sitting at a KNOWN height (for resume: the stored tip
  is not genesis — it's block N, so it must resume at height N, not 0). The next
  block then connects at N+1 and the tip reports the real chain height. Genesis
  (`new/1`) is just the height-0 case. (We anchor at the tip with its height and
  track forward; ancestry below the resume point is not reloaded — see "best leaf"
  resume.)
  """
  @spec new_at(hash(), non_neg_integer()) :: t()
  def new_at(root, height) when is_integer(height) and height >= 0 do
    %__MODULE__{
      root: root,
      # nil (genesis prev_hash) stays the origin at 0; the root sits at `height`.
      parents: %{root => nil},
      heights: %{root => height, nil => 0},
      children: %{},
      best: {height, root}
    }
  end

  @doc "Add a header `%{hash, parent_hash}`. Idempotent, out-of-order safe, O(1) amortised."
  @spec add(t(), header()) :: t()
  def add(%__MODULE__{} = f, %{hash: hash, parent_hash: parent}) do
    cond do
      hash == f.root -> f
      Map.has_key?(f.parents, hash) -> f
      true -> do_add(f, hash, parent)
    end
  end

  defp do_add(f, hash, parent) do
    f = %{
      f
      | parents: Map.put(f.parents, hash, parent),
        children: Map.update(f.children, parent, MapSet.new([hash]), &MapSet.put(&1, hash))
    }

    case Map.get(f.heights, parent) do
      nil ->
        # Parent absent or itself unconnected → this node is (for now) floating.
        # Store nil. BUT this node might be the block that connects a fragment
        # waiting on IT — so cascade in case children are already waiting.
        f = put_in(f.heights[hash], nil)
        cascade(f, hash)

      ph when is_integer(ph) ->
        # Parent connected → we get a real height; cascade to any waiting children.
        f = put_in(f.heights[hash], ph + 1)
        f = bump_best(f, ph + 1, hash)
        cascade(f, hash)
    end
  end

  # Forward-fill heights for descendants of `node`, but only when `node` itself
  # has a real height. Walks only the newly-connected fragment, each node once.
  defp cascade(f, node) do
    case Map.get(f.heights, node) do
      nil ->
        f

      h ->
        f.children
        |> Map.get(node, MapSet.new())
        |> Enum.reduce(f, fn child, acc ->
          if Map.get(acc.heights, child) == nil and Map.has_key?(acc.parents, child) do
            acc = put_in(acc.heights[child], h + 1)
            acc = bump_best(acc, h + 1, child)
            cascade(acc, child)
          else
            acc
          end
        end)
    end
  end

  # Track the best connected tip incrementally (greatest height; tie-break by hash).
  defp bump_best(f, height, hash) do
    {bh, bhash} = f.best

    if height > bh or (height == bh and hash_key(hash) > hash_key(bhash)) do
      %{f | best: {height, hash}}
    else
      f
    end
  end

  @doc "Is `hash` present AND connected back to the root? O(1)."
  @spec connected?(t(), hash()) :: boolean()
  def connected?(%__MODULE__{} = f, hash), do: is_integer(Map.get(f.heights, hash))

  @doc "Stored height (0 = root), or `nil` if not connected to the root. O(1)."
  @spec height(t(), hash()) :: non_neg_integer() | nil
  def height(%__MODULE__{} = f, hash), do: Map.get(f.heights, hash)

  @doc "Children hashes of `parent` (the fork set), as a list."
  @spec children(t(), hash()) :: [hash()]
  def children(%__MODULE__{} = f, parent) do
    f.children |> Map.get(parent, MapSet.new()) |> MapSet.to_list()
  end

  @doc "Current tip: a connected rollback override if set, else the best connected leaf. O(1)."
  @spec tip(t()) :: hash()
  def tip(%__MODULE__{tip_override: o} = f) when o != nil do
    if connected?(f, o), do: o, else: elem(f.best, 1)
  end

  def tip(%__MODULE__{best: {_h, hash}}), do: hash

  @doc "Move the tip back to `point` (must be connected). No-op otherwise."
  @spec rollback(t(), hash()) :: t()
  def rollback(%__MODULE__{} = f, point) do
    if connected?(f, point), do: %{f | tip_override: point}, else: f
  end

  @doc """
  Connected LEAVES — the open tips of the belief — ordered best-first (greatest
  height, tie-broken by hash). A leaf is a connected node with no connected child.

  This is the set of candidate resume points: at shutdown there may be SEVERAL open
  tips (competing forks in the volatile window), and chain-sync `FindIntersect`
  takes a LIST of points precisely so we can offer all of them and let the relay
  pick the most recent one it shares. The header table stores everything verdict-
  free; only CONNECTED leaves are eligible here (later: connected AND valid). Excludes
  the root-only case (a fresh forest has no real leaves to resume from → []).
  """
  @spec leaves(t()) :: [hash()]
  def leaves(%__MODULE__{} = f) do
    f.heights
    |> Enum.filter(fn {hash, h} ->
      # Exclude both the root AND nil (the genesis-prev alias for the origin) — they
      # are the origin, not real candidate tips.
      is_integer(h) and hash != f.root and not is_nil(hash) and leaf?(f, hash)
    end)
    |> Enum.sort_by(fn {hash, h} -> {h, hash_key(hash)} end, :desc)
    |> Enum.map(&elem(&1, 0))
  end

  # A connected node with no CONNECTED children (floating children don't count — the
  # node is still an open tip until a child actually connects onto it).
  defp leaf?(f, hash) do
    f.children
    |> Map.get(hash, MapSet.new())
    |> Enum.all?(fn child -> not connected?(f, child) end)
  end

  @doc """
  A bounded view of the region around the tip, for the live UI. Returns a list of
  rows from the tip backwards (newest first), each `%{height, hash, fork?}`:

    * the **spine** — the last `depth` ancestors of the tip, height-labelled;
    * any **forks** — sibling children of a spine node's parent that are NOT on the
      spine, flagged `fork?: true` (a parent with >1 child = a real fork point).

  Bounded to the tip neighbourhood so it stays cheap and small regardless of forest
  size. Also reports global `forks` (parents with >1 child) and `floating` (present
  but unconnected, height nil) counts so the UI can badge them even when off-screen.
  """
  @spec view(t(), pos_integer()) :: %{
          tip: hash(),
          tip_height: non_neg_integer() | nil,
          node_count: non_neg_integer(),
          forks: non_neg_integer(),
          floating: non_neg_integer(),
          rows: [%{height: non_neg_integer() | nil, hash: hash(), fork?: boolean()}]
        }
  def view(%__MODULE__{} = f, depth \\ 12) do
    tip = tip(f)
    rows = spine_rows(f, tip, depth, [])

    %{
      tip: tip,
      tip_height: height(f, tip),
      node_count: map_size(f.parents),
      forks: count_forks(f),
      floating: count_floating(f),
      rows: rows
    }
  end

  # Walk from `node` back toward the root, collecting up to `depth` spine rows;
  # at each step, emit any sibling forks (other children of the parent) before the
  # spine node itself, so newest-first order reads tip → ... → root.
  defp spine_rows(_f, _node, 0, acc), do: Enum.reverse(acc)

  defp spine_rows(f, node, depth, acc) do
    parent = Map.get(f.parents, node)
    row = %{height: height(f, node), hash: node, fork?: false}

    forks =
      f.children
      |> Map.get(parent, MapSet.new())
      |> MapSet.delete(node)
      |> Enum.map(fn h -> %{height: height(f, h), hash: h, fork?: true} end)

    acc = forks ++ [row | acc]

    cond do
      node == f.root -> Enum.reverse(acc)
      is_nil(parent) -> Enum.reverse(acc)
      not Map.has_key?(f.parents, parent) -> Enum.reverse(acc)
      true -> spine_rows(f, parent, depth - 1, acc)
    end
  end

  defp count_forks(f),
    do: Enum.count(f.children, fn {_p, kids} -> MapSet.size(kids) > 1 end)

  defp count_floating(f),
    do: Enum.count(f.heights, fn {_h, height} -> is_nil(height) end)

  defp hash_key(h) when is_binary(h), do: h
  defp hash_key(h), do: :erlang.term_to_binary(h)
end
