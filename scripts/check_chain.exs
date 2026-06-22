# Forensic integrity check: walk every header in the durable store and confirm the
# parent_hash links are sound. Read-only — never writes.
#
#   mix run scripts/check_chain.exs
#
# Reports, over all stored headers:
#   * total count
#   * roots (prev_hash = nil) — should be exactly the genesis/origin (or our resume
#     anchor, which legitimately has no stored parent)
#   * BROKEN links: a header whose prev_hash is non-nil but names a header we DON'T
#     have (a dangling parent — a real gap or corruption)
#   * forks: a hash that is the prev_hash of MORE THAN ONE header (a branch point)
#   * block_no continuity: gaps/dups in the block-number sequence on the main line
#
# This is the "do the parent links all match up?" check.

require Logger
alias Cardamom.ChainStore

headers = ChainStore.all_headers()
n = length(headers)
IO.puts("\n=== chain integrity over #{n} stored headers ===\n")

# Index by hash for O(1) parent lookup.
by_hash = Map.new(headers, fn h -> {h.hash, h} end)
short = fn nil -> "nil"; b -> Base.encode16(b, case: :lower) |> String.slice(0, 12) end

# Roots: no parent in our store (prev_hash nil = genesis, OR prev_hash present but
# not stored = our resume anchor / a gap head).
{roots, linked} = Enum.split_with(headers, fn h -> is_nil(h.prev_hash) end)

# Broken links: prev_hash is set but the named parent isn't in the store.
broken =
  Enum.filter(linked, fn h -> not Map.has_key?(by_hash, h.prev_hash) end)

# Forks: a parent hash claimed by >1 child.
fork_points =
  linked
  |> Enum.group_by(& &1.prev_hash)
  |> Enum.filter(fn {_p, kids} -> length(kids) > 1 end)

IO.puts("roots (prev_hash = nil):           #{length(roots)}")
for r <- roots, do: IO.puts("    root: #{short.(r.hash)} (block_no #{r.block_no}, slot #{r.slot})")

IO.puts("headers with a parent:             #{length(linked)}")
IO.puts("BROKEN links (parent not stored):  #{length(broken)}")

for h <- Enum.take(broken, 20) do
  IO.puts("    #{short.(h.hash)} (block #{h.block_no}) -> MISSING parent #{short.(h.prev_hash)}")
end

if length(broken) > 20, do: IO.puts("    ... and #{length(broken) - 20} more")

IO.puts("fork points (parent w/ >1 child):  #{length(fork_points)}")
for {p, kids} <- Enum.take(fork_points, 20) do
  IO.puts("    parent #{short.(p)} has #{length(kids)} children: #{Enum.map_join(kids, ", ", &short.(&1.hash))}")
end

# Block-number continuity on the stored set (sorted): report gaps and duplicates.
nos = headers |> Enum.map(& &1.block_no) |> Enum.sort()
{gaps, dups} =
  nos
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.reduce({[], []}, fn [a, b], {g, d} ->
    cond do
      b == a -> {g, [a | d]}
      b == a + 1 -> {g, d}
      true -> {[{a, b} | g], d}
    end
  end)

IO.puts("\nblock_no range:                    #{List.first(nos)}..#{List.last(nos)}")
IO.puts("block_no gaps:                     #{length(gaps)}")
for {a, b} <- Enum.take(Enum.reverse(gaps), 20), do: IO.puts("    gap: #{a} -> #{b} (missing #{b - a - 1})")
IO.puts("block_no duplicates:               #{length(Enum.uniq(dups))}")

verdict =
  cond do
    broken != [] -> "FAIL — #{length(broken)} broken parent link(s)"
    gaps != [] -> "INCOMPLETE — #{length(gaps)} block-number gap(s) (expected if we resumed/forked; not a link break)"
    true -> "OK — every parent_hash resolves to a stored header; contiguous"
  end

IO.puts("\n=== verdict: #{verdict} ===\n")
