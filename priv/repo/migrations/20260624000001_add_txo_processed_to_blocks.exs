defmodule Cardamom.Store.Repo.Migrations.AddTxoProcessedToBlocks do
  use Ecto.Migration

  # Marks a stored block whose transactions have been FULLY extracted into the TXO engine
  # (outputs created, inputs spent or a retrier spawned). This is the recovery ledger: spawn-
  # and-retry deferred spends die on a crash/restart, so on boot (and periodically) we re-run
  # process_block for any block still flagged false, self-healing any dangling spend without a
  # durable pending-spend table — the block's `raw` is already stored, so re-processing is just
  # an idempotent replay (UPSERT outputs + fail-fast spends).
  #
  # Default false so EXISTING rows (pre-migration) are swept on the next boot/reconcile.
  def change do
    alter table(:blocks) do
      add :txo_processed, :boolean, default: false, null: false
    end

    # The reconciler's hot query: "which stored blocks still need TXO extraction?"
    create index(:blocks, [:txo_processed])
  end
end
