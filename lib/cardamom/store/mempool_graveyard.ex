defmodule Cardamom.Store.MempoolGraveyard do
  @moduledoc """
  Forensic record of mempool TXOs that LEFT the live mempool — same TXO columns plus
  WHY (`reason`: confirmed | replaced | expired | …) and WHEN (`buried_at`). The live
  mempool supports delete; this keeps the departed for observation/analysis.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "mempool_graveyard" do
    field :txid, :binary
    field :ix, :integer
    field :address, :binary
    field :value, :integer
    field :datum_hash, :binary
    field :datum, :binary
    field :raw, :binary
    field :created_txid, :binary
    field :spent_by, :binary
    field :reason, :string
    field :buried_at, :integer
  end

  @fields [
    :txid, :ix, :address, :value, :datum_hash, :datum, :raw, :created_txid, :spent_by,
    :reason, :buried_at
  ]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:txid, :ix, :reason])
  end
end
