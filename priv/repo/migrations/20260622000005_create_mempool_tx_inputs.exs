defmodule Cardamom.Store.Repo.Migrations.CreateMempoolTxInputs do
  use Ecto.Migration

  # The spend-graph EDGE set for pending mempool txs: which UTxO each pending tx depends
  # on, and HOW. The many-to-many "find pending txs by their inputs" index — the
  # substrate for BOTH cascade-invalidation (a block spends X → who depended on X?) and
  # the separation oracle (Ramsay's "Separation of Z operations": disjoint Δ footprints).
  #
  # kind (Agda Conway Utxo.lagda.md):
  #   "spend"      — Δ: the tx consumes this UTxO (txIns). Removed from the set when applied.
  #   "reference"  — Ξ: read-only (refInputs); must be unspent but NOT consumed. A spend of
  #                  it elsewhere still invalidates the reader.
  #   "collateral" — consumed only if the tx fails phase-2.
  def change do
    create table(:mempool_tx_inputs, primary_key: false) do
      add :input_txid, :binary, null: false
      add :input_ix, :integer, null: false
      add :spender_txid, :binary, null: false
      add :kind, :string, null: false
    end

    # The hot cascade query: "who depends on UTxO X?" (all kinds).
    create index(:mempool_tx_inputs, [:input_txid, :input_ix])
    # "what does pending tx T touch?" (cleanup / footprint / separation).
    create index(:mempool_tx_inputs, [:spender_txid])
    # An edge is unique per (input, spender, kind).
    create unique_index(:mempool_tx_inputs, [:input_txid, :input_ix, :spender_txid, :kind])
  end
end
