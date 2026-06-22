defmodule Cardamom.Store.Block do
  @moduledoc """
  A block row in the durable store — block-LEVEL columns (M1: not into tx internals
  yet). Same rule as headers: keep the VERBATIM raw block bytes (so the body hash
  re-verifies and bodies can be served back byte-faithfully) alongside decoded
  columns we query on. Keyed by the block's identity = its HEADER hash (the same
  hash the forest/headers table uses), so a block joins 1:1 to its header.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:hash, :binary, autogenerate: false}
  schema "blocks" do
    field :slot, :integer
    field :block_no, :integer
    field :tx_count, :integer
    field :raw, :binary
  end

  @fields [:hash, :slot, :block_no, :tx_count, :raw]
  @required [:hash, :raw]

  def changeset(block, attrs) do
    block
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end
end
