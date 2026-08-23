defmodule Cardamom.Ledger.Praos.Continuity do
  @moduledoc """
  Tier-1 header CONTINUITY (Praos): a header must link to its parent — the hash chain plus the
  block-number and slot ordering that the hash link alone doesn't enforce.

  Pure over `(header, parent)`; `Cardamom.Ledger.HeaderHandler` resolves the parent from the store
  by the header's `prev_hash` and injects it (or `:not_found`). Because the parent is looked up BY
  `prev_hash`, the hash link — `prev_hash == blake2b(parent bytes)` — holds by construction of the
  lookup (a stored header's key IS blake2b of its received bytes); this check adds the ordering:

    * `prev_hash = nil` ⇒ genesis / era-start: no parent, continuity is vacuous — UNLESS
      `block_number > 0`, which is impossible without a parent (an orphan claiming to be non-first).
    * `parent = :not_found` ⇒ SKIP: the parent hasn't arrived yet. Out-of-order arrival is normal
      (the forest files-don't-chases and resolves it later) — never a false reject.
    * parent present ⇒ `block_number = parent.block_no + 1` AND `slot > parent.slot`.

  Returns `:ok | {:skip, reason} | {:invalid, reason}` — the header gate's verdict shape.
  """

  @spec check(map(), map() | :not_found) :: :ok | {:skip, term()} | {:invalid, term()}
  def check(%{prev_hash: nil, block_number: 0}, _parent), do: :ok

  def check(%{prev_hash: nil, block_number: n}, _parent),
    do: {:invalid, {:orphan_nonzero_block, n}}

  def check(%{prev_hash: prev}, :not_found) when is_binary(prev),
    do: {:skip, :parent_not_found}

  def check(%{block_number: n, slot: slot}, %{block_no: pn, slot: ps}) do
    cond do
      n != pn + 1 -> {:invalid, {:block_number, %{expected: pn + 1, got: n}}}
      slot <= ps -> {:invalid, {:slot_not_increasing, %{slot: slot, parent_slot: ps}}}
      true -> :ok
    end
  end

  # Anything malformed (missing fields) — don't assert continuity on a header we can't read.
  def check(_header, _parent), do: {:skip, :continuity_unreadable}
end
