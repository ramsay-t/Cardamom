defmodule Cardamom.PeerStore.Static do
  @moduledoc """
  In-memory `Cardamom.PeerStore` for tests/dev: seeded from a fixed list, all
  state in a single process, NEVER touches SQL. This is the default peer store
  for tests so the suite cannot pollute real peer data. Each instance is
  independent (no global/shared state).

  `start_link/1` returns `{:ok, {__MODULE__, pid}}` — a `PeerStore` handle ready
  to pass to the `Cardamom.PeerStore` dispatch functions.
  """

  @behaviour Cardamom.PeerStore

  use GenServer

  @doc """
  Opts: `:seed` (list of known peers, may include `:quality`), `:bootstrap`
  (cold-start fallback peers).
  """
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} -> {:ok, {__MODULE__, pid}}
      other -> other
    end
  end

  # ---- behaviour ----

  @impl Cardamom.PeerStore
  def list_known(pid), do: GenServer.call(pid, :list_known)

  @impl Cardamom.PeerStore
  def bootstrap_peers(pid), do: GenServer.call(pid, :bootstrap_peers)

  @impl Cardamom.PeerStore
  def record(pid, obs), do: GenServer.call(pid, {:record, obs})

  @impl Cardamom.PeerStore
  def observations(pid), do: GenServer.call(pid, :observations)

  # ---- GenServer ----

  @impl true
  def init(opts) do
    seed = Keyword.get(opts, :seed, [])

    known =
      Map.new(seed, fn p -> {{p.host, p.port}, Map.put_new(p, :quality, 0)} end)

    {:ok,
     %{
       known: known,
       bootstrap: Keyword.get(opts, :bootstrap, []),
       observations: []
     }}
  end

  @impl true
  def handle_call(:list_known, _from, state) do
    ranked =
      state.known
      |> Map.values()
      |> Enum.sort_by(&Map.get(&1, :quality, 0), :desc)

    {:reply, ranked, state}
  end

  def handle_call(:bootstrap_peers, _from, state),
    do: {:reply, state.bootstrap, state}

  def handle_call({:record, obs}, _from, state) do
    key = {obs.host, obs.port}

    known =
      Map.update(
        state.known,
        key,
        %{host: obs.host, port: obs.port, quality: 0},
        & &1
      )

    {:reply, :ok, %{state | known: known, observations: [obs | state.observations]}}
  end

  def handle_call(:observations, _from, state),
    do: {:reply, Enum.reverse(state.observations), state}
end
