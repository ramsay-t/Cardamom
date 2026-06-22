defmodule Cardamom.Store.Repo.Migrations.CreatePeers do
  use Ecto.Migration

  # Durable peer reputation. One row per (host, port); `quality` is a single score moved
  # by per-event deltas (clean session up, failure/violation down). list_known ranks by
  # it for hot-start dialing. This is the persistent backing for the PeerStore behaviour
  # (vs the in-memory Static) and the foundation for the trust layer (security.md).
  def change do
    create table(:peers, primary_key: false) do
      add :host, :string, null: false
      add :port, :integer, null: false
      add :quality, :integer, null: false, default: 0
      add :last_event, :string
      add :last_seen, :integer
    end

    create unique_index(:peers, [:host, :port])
    create index(:peers, [:quality])
  end
end
