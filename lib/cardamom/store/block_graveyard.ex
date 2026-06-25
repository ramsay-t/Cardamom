defmodule Cardamom.Store.BlockGraveyard do
  @moduledoc """
  A block orphaned by a ROLLBACK (reorg): it was on a fork the chain abandoned. Kept for
  forensics — the live `blocks` table + UTxO set reflect only the winning chain, but this
  records what lost, and the slot we rolled back TO when it was orphaned. Mirrors the live
  Block row (verbatim raw bytes preserved) plus `rolled_back_to_slot`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:hash, :binary, autogenerate: false}
  schema "block_graveyard" do
    field :slot, :integer
    field :block_no, :integer
    field :tx_count, :integer
    field :raw, :binary
    field :rolled_back_to_slot, :integer
  end

  @fields [:hash, :slot, :block_no, :tx_count, :raw, :rolled_back_to_slot]
  @required [:hash]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end
end
