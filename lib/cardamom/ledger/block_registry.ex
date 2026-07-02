defmodule Cardamom.Ledger.BlockRegistry do
  @moduledoc """
  Unique Registry mapping a block's (header) hash → its live `Cardamom.Ledger.BlockHandler` pid.

  This is how `Cardamom.ChainStore.rollback/1` finds the in-flight handlers for orphaned blocks so
  it can terminate them (cascading the cancel to their tx retriers), and how `BlockSupervisor`
  dedupes: a second `start_block/3` for the same hash collides on the registered name and returns
  the existing pid. The Registry entry is removed automatically when the handler process dies.
  """

  @doc false
  def child_spec(_arg) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end
end
