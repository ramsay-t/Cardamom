defmodule Cardamom.Ledger.Delta do
  @moduledoc """
  INVERTIBLE per-block ledger-state deltas — the rollback mechanism (Ramsay's formulation: a block
  produces a forward delta; rollback applies its inverse). A delta is a LIST OF OPS; each op knows
  how to `apply/1` (forward) and `invert/1` (produce the op that undoes it). Rollback = the block's
  ops, reversed, each inverted, applied.

  THE INVERTIBILITY RULE (the crux): additive ops (fees += n, deposit add, pool register) invert
  themselves; but DESTRUCTIVE OVERWRITES (re-delegation poolA→poolB, drep-expiry reset) are NOT
  invertible from the forward value alone — the op MUST CAPTURE THE DISPLACED OLD VALUE. So a
  `:set` op carries {key, old, new}; its inverse is `:set` {key, new, old}. (The UTxO set was easy
  because txos are monotone — created once, spent once; accounting state has real overwrites.)

  Ops are PURE DATA (tuples); this module is the apply/invert logic (versioned, testable). The
  journal (Cardamom.Ledger.DeltaLog) persists the op-list per block as an :erlang.term_to_binary
  blob keyed by slot, pruned at rollback depth k. Ops call Cardamom.ChainStore setters to mutate
  the materialised state tables. State-target atoms are a CLOSED SET (below) — never String.to_atom.

  OP FORMS:
    {:add,  domain, key, n}              -- scalar add (fees, a pot, a deposit coin) ; inverse :add -n
    {:put,  domain, key, value}          -- insert where absent (register) ; inverse :del
    {:del,  domain, key, old_value}      -- remove, capturing old ; inverse :put old_value
    {:set,  domain, key, old, new}       -- OVERWRITE, captures old ; inverse :set new→old
  `domain` names the state map (a closed atom set): :fees | :pot | :deposit | :stake_deleg |
    :vote_deleg | :pool | :pool_retiring | :drep | :cc_hot | :reward.
  """

  alias Cardamom.ChainStore

  @domains ~w(fees pot deposit stake_deleg vote_deleg pool pool_retiring drep cc_hot reward)a

  @doc "Is this a known state domain? (closed set — guards against bad ops.)"
  def domain?(d), do: d in @domains

  @doc "The inverse op — the op that undoes `op`. Applying op then its inverse is a no-op."
  def invert({:add, dom, key, n}), do: {:add, dom, key, -n}
  def invert({:put, dom, key, value}), do: {:del, dom, key, value}
  def invert({:del, dom, key, old}), do: {:put, dom, key, old}
  def invert({:set, dom, key, old, new}), do: {:set, dom, key, new, old}

  @doc "Apply one op to the materialised state (via ChainStore). Best-effort; returns :ok."
  def apply_op({:add, dom, key, n}), do: ChainStore.ledger_add(dom, key, n)
  def apply_op({:put, dom, key, value}), do: ChainStore.ledger_put(dom, key, value)
  def apply_op({:del, dom, _key, _old} = op), do: ChainStore.ledger_del(dom, elem(op, 2))
  def apply_op({:set, dom, key, _old, new}), do: ChainStore.ledger_set(dom, key, new)

  @doc "Apply a forward delta (list of ops, in order)."
  def apply_forward(ops) when is_list(ops), do: Enum.each(ops, &apply_op/1)

  @doc "Apply the INVERSE of a delta — reverse order, each op inverted (the rollback)."
  def apply_inverse(ops) when is_list(ops) do
    ops |> Enum.reverse() |> Enum.each(fn op -> apply_op(invert(op)) end)
  end
end
