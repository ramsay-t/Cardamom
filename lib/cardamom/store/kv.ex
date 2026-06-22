defmodule Cardamom.Store.Kv do
  @moduledoc """
  A tiny durable key/value table for small singletons — currently the chain TIP
  (so a restart resumes from the last point via FindIntersect instead of genesis).
  Typed columns, not a blob dumping ground.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "kv" do
    field :value, :binary
  end

  def changeset(kv, attrs) do
    kv
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end
