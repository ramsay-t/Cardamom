defmodule Cardamom.Store.MempoolTxInput do
  @moduledoc """
  One edge of the pending-tx spend graph: pending `spender_txid` depends on UTxO
  `(input_txid, input_ix)` with `kind` "spend" (Δ) | "reference" (Ξ) | "collateral".
  The reverse index (input → spenders) drives cascade-invalidation and the separation
  oracle. See reference_agda_utxo_separation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "mempool_tx_inputs" do
    field :input_txid, :binary, primary_key: true
    field :input_ix, :integer, primary_key: true
    field :spender_txid, :binary, primary_key: true
    field :kind, :string, primary_key: true
  end

  @fields [:input_txid, :input_ix, :spender_txid, :kind]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required(@fields)
  end
end
