defmodule Cardamom.PeerSharing.Client do
  @moduledoc """
  Drives the PeerSharing mini-protocol (10). OBSERVE, DON'T ACT:

    * On start, as initiator, we send `MsgShareRequest(amount)` and RECORD the addresses
      the peer returns (`MsgSharePeers`) as low-trust CANDIDATES in the PeerStore. We do
      NOT dial them — accepting a network-sourced address for *dialing* needs the trust
      layer (scoring, eclipse-resistance, source caps; see security.md), which isn't
      built. Discovery is legitimate; trusting/acting on it is the gated part.
    * We participate honestly: if the PEER asks us to share, we reply `MsgSharePeers`
      with peers we know (from the PeerStore).

  A process holding the bearer, like every mini-protocol; registers for proto 10.

  Opts:
    * `:conn`           — bearer pid (required)
    * `:peer`           — label for logs
    * `:peer_store`     — `{module, handle}` PeerStore (record candidates / list known)
    * `:request_amount` — how many peers to ask for (word8; default 10)
  """
  use GenServer
  require Logger

  alias Cardamom.PeerStore
  alias Cardamom.Protocol.PeerSharing.Codec

  @peer_sharing 10
  @default_amount 10

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    Process.link(conn)
    Process.flag(:trap_exit, true)
    :ok = Cardamom.Connection.register(conn, @peer_sharing)

    state = %{
      conn: conn,
      peer: Keyword.get(opts, :peer, "loopback"),
      peer_store: Keyword.get(opts, :peer_store),
      amount: Keyword.get(opts, :request_amount, @default_amount)
    }

    # As initiator: ask the peer for some addresses.
    Cardamom.Connection.send_frame(conn, @peer_sharing, Codec.encode({:share_request, state.amount}))
    {:ok, state}
  end

  @impl true
  def handle_info({:sdu, @peer_sharing, payload}, state) do
    case Codec.decode(payload) do
      {:ok, msg, _rest} -> {:noreply, on_msg(msg, state)}
      {:error, reason} ->
        Logger.warning("peer_sharing decode error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  # The peer replied with addresses — RECORD them as candidates. We do NOT dial.
  defp on_msg({:share_peers, peers}, state) do
    record_candidates(peers, state)
    state
  end

  # The peer asked US to share — reply honestly with what we know (bounded by `amount`).
  defp on_msg({:share_request, amount}, state) do
    known =
      case state.peer_store do
        {_m, _h} = store ->
          PeerStore.list_known(store)
          |> Enum.take(amount)
          |> Enum.map(&%{host: &1.host, port: &1.port})

        _ ->
          []
      end

    Cardamom.Connection.send_frame(state.conn, @peer_sharing, Codec.encode({:share_peers, known}))
    state
  end

  defp on_msg(:done, state), do: state
  defp on_msg(_other, state), do: state

  # Record each shared address as a low-trust candidate (quality unchanged by the
  # behaviour's neutral handling of an unknown event); it becomes dial-eligible only via
  # the (future) trust layer. Best-effort: no store configured ⇒ just observe + log.
  defp record_candidates(peers, %{peer_store: {_m, _h} = store, peer: label}) do
    Enum.each(peers, fn %{host: host, port: port} ->
      PeerStore.record(store, %{host: host, port: port, event: :peer_shared})

      :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{
        protocol: "peer_sharing",
        msg: "PeerShared",
        host: host,
        port: port
      })
    end)

    Logger.info("peer_sharing #{label}: recorded #{length(peers)} candidate(s) (NOT dialed)")
  end

  defp record_candidates(peers, _state),
    do: Logger.info("peer_sharing: received #{length(peers)} peer(s), no store to record into")
end
