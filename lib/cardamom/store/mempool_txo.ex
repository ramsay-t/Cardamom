defmodule Cardamom.Store.MempoolTxo do
  @moduledoc """
  A PENDING (mempool) transaction output. Identical columns to `Cardamom.Store.Txo`
  (the confirmed/on-chain TXO) so the two tables JOIN cleanly when validating mempool
  actions against the chain. The table you read IS the verdict: a row here is pending,
  a row in `txos` is settled on chain. No shared table, no WHERE-filter to forget.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @fields [:txid, :ix, :address, :value, :datum_hash, :datum, :raw, :created_txid, :spent_by]
  def fields, do: @fields

  @primary_key false
  schema "mempool_txos" do
    field :txid, :binary, primary_key: true
    field :ix, :integer, primary_key: true
    field :address, :binary
    field :value, :integer
    field :datum_hash, :binary
    field :datum, :binary
    field :raw, :binary
    field :created_txid, :binary
    field :spent_by, :binary
  end

  def changeset(txo, attrs) do
    txo
    |> cast(attrs, @fields)
    |> validate_required([:txid, :ix])
  end
end
