defmodule Cardamom.Store.Txo do
  @moduledoc """
  A transaction output row — the entity with a create→spend lifecycle. Keyed (txid, ix):
  the exact reference a spending tx's input carries. `spent_by` is null while UNSPENT
  (a UTXO) and the spending txid once consumed; the UTXO set is `WHERE spent_by IS NULL`.

  `datum`/`datum_hash` are the goal-(b) payload (a contract's current state). `raw` is
  the verbatim output bytes (forensic). The full tx isn't stored here — it lives in the
  block raw (Blocks table); only the OUTPUTS, the thing that gets spent, live as rows.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "txos" do
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

  @fields [:txid, :ix, :address, :value, :datum_hash, :datum, :raw, :created_txid, :spent_by]
  @required [:txid, :ix]

  def changeset(txo, attrs) do
    txo
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end
end
