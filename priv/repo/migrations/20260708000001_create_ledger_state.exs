defmodule Cardamom.Store.Repo.Migrations.CreateLedgerState do
  use Ecto.Migration

  # The non-UTxO accounting state (Tier a), as a single generic key->value table. The ledger's
  # accounting substate is a set of heterogeneous MAPS (credential->pool, purpose->coin,
  # pool->params, drep->entry, ...); all are "domain, key -> value" with point-lookup access, so
  # one table keyed (domain, key) is the pragmatic BEAM-native fit rather than a table per map
  # (matches the design: match the spec's BEHAVIOUR, not its record shape). `value` is our own
  # term_to_binary blob. `slot` stamps the last-writing block (diagnostic; rollback is driven by
  # the invertible delta journal, not a slot sweep).
  def change do
    create table(:ledger_state, primary_key: false) do
      add :domain, :string, primary_key: true
      add :key, :binary, primary_key: true
      add :value, :binary
      add :slot, :integer
    end

    # The per-block INVERTIBLE DELTA JOURNAL (rollback mechanism). Each row is one block's op-list
    # (term_to_binary), keyed by slot; pruned beyond rollback depth k. Rollback reads slot > point
    # descending and applies each delta's inverse.
    create table(:ledger_deltas, primary_key: false) do
      add :slot, :integer, primary_key: true
      add :block_hash, :binary
      add :ops, :binary
    end
  end
end
