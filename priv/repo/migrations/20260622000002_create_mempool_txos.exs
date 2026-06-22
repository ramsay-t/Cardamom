defmodule Cardamom.Store.Repo.Migrations.CreateMempoolTxos do
  use Ecto.Migration

  # Mempool (pending/speculative) TXOs — SEPARATE from confirmed `txos`, with an
  # IDENTICAL column set so JOINs across the two "just work" (validating a pending tx's
  # spends against the confirmed chain). Structure is the verdict: a row here is PENDING,
  # a row in `txos` is ON CHAIN. Lifecycle: add on receipt, DELETE on confirm/replace/
  # expire — deletes are copied to the graveyard for forensics.
  def change do
    create table(:mempool_txos, primary_key: false) do
      add :txid, :binary, null: false
      add :ix, :integer, null: false
      add :address, :binary
      add :value, :integer
      add :datum_hash, :binary
      add :datum, :binary
      add :raw, :binary
      add :created_txid, :binary
      add :spent_by, :binary
    end

    create unique_index(:mempool_txos, [:txid, :ix])
    create index(:mempool_txos, [:address])

    # Forensic graveyard: every mempool TXO that LEFT the live mempool, plus WHY and
    # WHEN. Same TXO columns + reason/at. Not unique on (txid, ix) — a tx could in
    # principle reappear; we keep every departure as a record.
    create table(:mempool_graveyard, primary_key: false) do
      add :txid, :binary, null: false
      add :ix, :integer, null: false
      add :address, :binary
      add :value, :integer
      add :datum_hash, :binary
      add :datum, :binary
      add :raw, :binary
      add :created_txid, :binary
      add :spent_by, :binary
      # why it left the live mempool: "confirmed" | "replaced" | "expired" | ...
      add :reason, :string
      add :buried_at, :integer
    end

    create index(:mempool_graveyard, [:txid])
  end
end
