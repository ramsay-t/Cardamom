defmodule Cardamom.Store.LedgerState do
  @moduledoc """
  One entry of the non-UTxO accounting state: `(domain, key) -> value`. Generic key->value over the
  ledger's heterogeneous maps (delegations, deposits, pools, dreps, cc, rewards, pots). `key` and
  `value` are our own term_to_binary blobs. Written/rolled-back via the invertible delta journal.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "ledger_state" do
    field :domain, :string, primary_key: true
    field :key, :binary, primary_key: true
    field :value, :binary
    field :slot, :integer
  end

  @fields [:domain, :key, :value, :slot]
  def changeset(row, attrs), do: row |> cast(attrs, @fields) |> validate_required([:domain, :key])
end
