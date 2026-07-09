defmodule Cardamom.Store.LedgerDelta do
  @moduledoc """
  One block's INVERTIBLE ledger-state delta: the op-list (Cardamom.Ledger.Delta ops) that block
  applied, term_to_binary'd, keyed by slot. The rollback journal — pruned beyond rollback depth k.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "ledger_deltas" do
    field :slot, :integer, primary_key: true
    field :block_hash, :binary
    field :ops, :binary
  end

  @fields [:slot, :block_hash, :ops]
  def changeset(row, attrs), do: row |> cast(attrs, @fields) |> validate_required([:slot, :ops])
end
