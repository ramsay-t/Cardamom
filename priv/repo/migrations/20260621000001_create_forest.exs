defmodule Cardamom.Store.Repo.Migrations.CreateForest do
  use Ecto.Migration

  def change do
    create table(:headers, primary_key: false) do
      add :hash, :binary, primary_key: true
      add :prev_hash, :binary
      add :slot, :integer, null: false
      add :block_no, :integer, null: false
      # Forensic columns (decoded from the header):
      add :issuer_vkey, :binary
      add :vrf_vkey, :binary
      add :block_body_size, :integer
      add :block_body_hash, :binary
      add :protocol_major, :integer
      add :protocol_minor, :integer
      # Verbatim wire bytes (hash fidelity):
      add :raw, :binary, null: false
    end

    # Forensic/lookup support: chain order, forest linkage, and "blocks by issuer".
    create index(:headers, [:slot])
    create index(:headers, [:prev_hash])
    create index(:headers, [:issuer_vkey])

    create table(:kv, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :binary, null: false
    end
  end
end
