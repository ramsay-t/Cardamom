defmodule Cardamom.Store.Repo.Migrations.CreateTxos do
  use Ecto.Migration

  # Transaction outputs (spent or not), keyed (txid, ix). The UTXO set is the VIEW
  # `WHERE spent_by IS NULL`. We spend TXOs, not txs — the output is the entity with a
  # create→spend lifecycle, so it's the row; an input's effect is to set spent_by here.
  def change do
    create table(:txos, primary_key: false) do
      add :txid, :binary, null: false
      add :ix, :integer, null: false
      add :address, :binary
      add :value, :integer
      add :datum_hash, :binary
      add :datum, :binary
      add :raw, :binary
      add :created_txid, :binary
      # null ⇒ unspent (a UTXO); the spending txid once consumed.
      add :spent_by, :binary
    end

    create unique_index(:txos, [:txid, :ix])
    # "TXOs at address X" and the UTXO-set view.
    create index(:txos, [:address])
    create index(:txos, [:spent_by])
  end
end
