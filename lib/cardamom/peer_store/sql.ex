defmodule Cardamom.PeerStore.Sql do
  @moduledoc """
  Durable `Cardamom.PeerStore` implementation, backed by Ecto/SQLite (the `peers`
  table). Same behaviour as the in-memory `Static`, but reputation PERSISTS across
  restarts (hot-start from last-known-good) and — the substantive part — `record/2`
  MOVES a peer's `quality` by a per-event delta, so reputation actually means something.

  Scoring (single score, +/- per event). Deliberately simple deltas; the relative
  ORDER is the contract (good raises, failures lower, a protocol violation costs most):
    * good behaviour (connected, clean_close, served)  → up
    * soft failures  (timeout, disconnect)             → down
    * protocol violation                               → down hardest

  The trust layer (eclipse-resistance: source caps, forced diversity) will sit ON TOP of
  this score; here we just maintain the score honestly. See security.md.
  """
  use GenServer
  @behaviour Cardamom.PeerStore

  import Ecto.Query
  alias Cardamom.Store.{Peer, Repo}

  # event → quality delta. Unknown events are neutral (0) but still register the peer.
  @deltas %{
    connected: 5,
    clean_close: 3,
    served: 2,
    disconnect: -3,
    timeout: -5,
    # Gossiping a definitively-invalid / undecodable tx: a real misbehaviour (but less
    # severe than a raw protocol violation — it could be a buggy, not malicious, peer).
    sent_invalid_tx: -10,
    sent_undecodable_tx: -10,
    protocol_violation: -25
  }

  # Returns the self-describing handle {__MODULE__, pid} (matching PeerStore.Static), so
  # callers pass it straight to the PeerStore behaviour dispatcher.
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: opts[:name]) do
      {:ok, pid} -> {:ok, {__MODULE__, pid}}
      other -> other
    end
  end

  @impl Cardamom.PeerStore
  def list_known(pid), do: GenServer.call(pid, :list_known)

  @impl Cardamom.PeerStore
  def bootstrap_peers(pid), do: GenServer.call(pid, :bootstrap_peers)

  @impl Cardamom.PeerStore
  def record(pid, obs), do: GenServer.call(pid, {:record, obs})

  @impl Cardamom.PeerStore
  def observations(_pid), do: []

  @impl true
  def init(opts) do
    {:ok, %{bootstrap: Keyword.get(opts, :bootstrap, [])}}
  end

  @impl true
  def handle_call(:list_known, _from, state) do
    rows =
      Repo.all(from p in Peer, order_by: [desc: p.quality])
      |> Enum.map(&%{host: &1.host, port: &1.port, quality: &1.quality})

    {:reply, rows, state}
  end

  def handle_call(:bootstrap_peers, _from, state),
    do: {:reply, state.bootstrap, state}

  def handle_call({:record, obs}, _from, state) do
    delta = Map.get(@deltas, obs.event, 0)
    now = System.system_time(:second)
    event = Atom.to_string(obs.event)

    existing = Repo.get_by(Peer, host: obs.host, port: obs.port)
    base = (existing && existing.quality) || 0

    %Peer{}
    |> Peer.changeset(%{
      host: obs.host,
      port: obs.port,
      quality: base + delta,
      last_event: event,
      last_seen: now
    })
    |> Repo.insert(
      on_conflict: [set: [quality: base + delta, last_event: event, last_seen: now]],
      conflict_target: [:host, :port]
    )

    {:reply, :ok, state}
  end
end
