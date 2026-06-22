defmodule Cardamom.Store.Peer do
  @moduledoc """
  A durable peer row: (host, port) identity + a single `quality` reputation score moved
  by per-event deltas. Ranked best-first for hot-start dialing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "peers" do
    field :host, :string, primary_key: true
    field :port, :integer, primary_key: true
    field :quality, :integer, default: 0
    field :last_event, :string
    field :last_seen, :integer
  end

  @fields [:host, :port, :quality, :last_event, :last_seen]

  def changeset(peer, attrs) do
    peer
    |> cast(attrs, @fields)
    |> validate_required([:host, :port])
  end
end
