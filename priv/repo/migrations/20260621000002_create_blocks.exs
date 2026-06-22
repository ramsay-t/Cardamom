defmodule Cardamom.Store.Repo.Migrations.CreateBlocks do
  use Ecto.Migration

  def change do
    create table(:blocks, primary_key: false) do
      add :hash, :binary, primary_key: true
      add :slot, :integer
      add :block_no, :integer
      add :tx_count, :integer
      # Verbatim block bytes (hash fidelity; serve-back faithful):
      add :raw, :binary, null: false
    end

    create index(:blocks, [:slot])
    create index(:blocks, [:block_no])
  end
end
