defmodule Cardamom.PeerSupervisor do
  @moduledoc """
  DynamicSupervisor for live peer sessions (Cardamom.Peer.Session). The Connector starts
  sessions HERE rather than dangling them off itself, so on app shutdown the supervision
  tree terminates each session with a bounded GRACEFUL window — its terminate/2 runs
  (MsgDone/MsgClientDone → FIN) before the socket closes. Before this, a boot-dialed
  session was an orphan that got killed abruptly on stop (no graceful goodbye on the wire).

  The session child shutdown timeout is generous (10s) so the polite close reaches the
  relay even mid-sync.
  """
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start a peer session under this supervisor (graceful shutdown on app stop)."
  def start_session(session_opts) do
    spec = %{
      id: Cardamom.Peer.Session,
      start: {Cardamom.Peer.Session, :start_link, [session_opts]},
      restart: :transient,
      # Give the session time to send MsgDone and FIN before the bearer closes.
      shutdown: 10_000
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
