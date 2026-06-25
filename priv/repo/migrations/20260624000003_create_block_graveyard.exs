defmodule Cardamom.Store.Repo.Migrations.CreateBlockGraveyard do
  use Ecto.Migration

  # Orphaned blocks from a ROLLBACK. When the chain reorgs to a fork, the blocks above the
  # rollback point are no longer on the winning chain — but we KEEP them here (like the mempool
  # graveyard) for forensics: "this fork existed, then lost". The live blocks table + UTxO set
  # reflect only the winning chain; the graveyard records what was orphaned, with the slot we
  # rolled back to (so a later re-roll-forward over the same fork is recognisable).
  def change do
    create table(:block_graveyard, primary_key: false) do
      add :hash, :binary, null: false, primary_key: true
      add :slot, :integer
      add :block_no, :integer
      add :tx_count, :integer
      add :raw, :binary
      # The point we rolled back TO when this block was orphaned (forensic context).
      add :rolled_back_to_slot, :integer
    end

    create index(:block_graveyard, [:slot])
  end
end
