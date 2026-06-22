defmodule Cardamom.PeerStore do
  @moduledoc """
  The peer data layer, as a **parameterised behaviour** so the storage backend is
  swappable. Tests/dev use `PeerStore.Static` (in-memory, seeded, NEVER touches
  SQL); production will use `PeerStore.Sql` (durable, ETS-hot + SQLite). The store
  is injected (a `{module, handle}` ref) exactly like `Cardamom.Channel`, so the
  test suite cannot pollute real peer data.

  Serves four uses (see architecture.md): network-observation history, cheap
  resume, trust/reputation, and hot-start from last-known-good peers. `list_known`
  returns peers RANKED (best-quality first) for hot-start dialing; `bootstrap_peers`
  is the cold-start fallback; `record` appends an observation (which also makes a
  peer known).
  """

  @type peer :: %{required(:host) => String.t(), required(:port) => non_neg_integer(), optional(atom()) => any()}
  @type observation :: %{required(:host) => String.t(), required(:port) => non_neg_integer(), required(:event) => atom(), optional(atom()) => any()}
  @type handle :: {module(), term()}

  @callback list_known(term()) :: [peer()]
  @callback bootstrap_peers(term()) :: [peer()]
  @callback record(term(), observation()) :: :ok
  @callback observations(term()) :: [observation()]

  # Dispatch on the {module, handle} ref.
  @spec list_known(handle()) :: [peer()]
  def list_known({mod, h}), do: mod.list_known(h)

  @spec bootstrap_peers(handle()) :: [peer()]
  def bootstrap_peers({mod, h}), do: mod.bootstrap_peers(h)

  @spec record(handle(), observation()) :: :ok
  def record({mod, h}, obs), do: mod.record(h, obs)

  @spec observations(handle()) :: [observation()]
  def observations({mod, h}), do: mod.observations(h)
end
