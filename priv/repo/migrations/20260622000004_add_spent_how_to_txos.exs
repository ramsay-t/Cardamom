defmodule Cardamom.Store.Repo.Migrations.AddSpentHowToTxos do
  use Ecto.Migration

  # spent_how records the MANNER a TXO was consumed, alongside spent_by (who):
  #   "tx_input"  — normally spent by a valid tx
  #   "collateral" — consumed as the phase-2 penalty of an invalid tx (failed scripts)
  # null while unspent. A forensic signal of failed smart-contract activity on chain.
  def change do
    alter table(:txos) do
      add :spent_how, :string
    end
  end
end
