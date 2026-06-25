defmodule Cardamom.Store.Repo.Migrations.AddSlotsToTxos do
  use Ecto.Migration

  # ROLLBACK support. A reorg rolls the chain back to an intersection point (a slot); everything
  # ABOVE that slot must be undone. To do that we must know which BLOCK (slot) each txo effect
  # belongs to — which the txo row didn't record (it only had created_txid / spent_by, txids with
  # no slot). Without these columns there is no way to know which txos to delete or which spends
  # to resurrect (Ramsay's point: "how would you know which ones to delete without the slot?").
  #
  #   created_slot — slot of the block that CREATED this output. Rollback deletes created_slot > P.
  #   spent_slot   — slot of the block that SPENT it (null = unspent). Rollback RESURRECTS
  #                  (spent_by → null) where spent_slot > P — the spent-UTXO-comes-back case.
  #
  # Both nullable: existing rows (pre-migration, deep settled history that never reorgs) stay
  # null and are simply never matched by a rollback's `> P` predicate. New writes stamp them.
  def change do
    alter table(:txos) do
      add :created_slot, :integer
      add :spent_slot, :integer
    end

    # Rollback's hot predicates: "outputs created above P" and "spends made above P".
    create index(:txos, [:created_slot])
    create index(:txos, [:spent_slot])
  end
end
