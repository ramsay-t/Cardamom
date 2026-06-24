defmodule Cardamom.PeerSharing.Client do
  @moduledoc """
  Drives the PeerSharing mini-protocol (10). OBSERVE, DON'T ACT:

    * On start, as initiator, we send `MsgShareRequest(amount)` and RECORD the addresses
      the peer returns (`MsgSharePeers`) as low-trust CANDIDATES via ChainStore (peers are chain data). We do
      NOT dial them — accepting a network-sourced address for *dialing* needs the trust
      layer (scoring, eclipse-resistance, source caps; see security.md), which isn't
      built. Discovery is legitimate; trusting/acting on it is the gated part.
    * We participate honestly: if the PEER asks us to share, we reply `MsgSharePeers`
      with peers we know (from ChainStore.known_peers).

  A process holding the bearer, like every mini-protocol; registers for proto 10.

  Recorded candidates / share-back come straight from the chain store (ChainStore.record_peer
  / known_peers) — peers are chain data (same magic, same DB), not a separate store.

  Opts:
    * `:conn`           — bearer pid (required)
    * `:peer`           — label for logs
    * `:request_amount` — how many peers to ask for (word8; default 10)
  """
  use GenServer
  require Logger

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
      amount: Keyword.get(opts, :request_amount, @default_amount)
    }

    # As initiator: ask the peer for some addresses.
    Cardamom.Connection.send_frame(conn, @peer_sharing, Codec.encode({:share_request, state.amount}))
    {:ok, state}
  end

  @impl true
  def handle_info({:sdu, @peer_sharing, payload}, state) do
    # Raw-byte capture, tagged :raw_bytes (dropped by the handler filter unless enabled; see
    # Cardamom.Debug). Matches chain_sync.
    Logger.debug(
      fn -> "peer_sharing raw payload: " <> Base.encode16(payload, case: :lower) end,
      Cardamom.Debug.tag()
    )

    case Codec.decode(payload) do
      {:ok, msg, _rest} ->
        emit_in(msg, state)
        {:noreply, on_msg(msg, state)}

      {:error, reason} ->
        Logger.warning("peer_sharing decode error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  # Log + telemetry the parsed inbound message (the decoded event, after the raw bytes).
  defp emit_in(msg, state) do
    Logger.info("peer_sharing #{state.peer} <- #{inbound_label(msg)}")

    :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{
      protocol: "peer_sharing",
      msg: inbound_label(msg),
      peer: state.peer
    })
  end

  defp inbound_label({:share_peers, peers}), do: "SharePeers(#{length(peers)})"
  defp inbound_label({:share_request, n}), do: "ShareRequest(#{n})"
  defp inbound_label(:done), do: "Done"
  defp inbound_label(other), do: inspect(other)

  # The peer replied with addresses — RECORD them as candidates. We do NOT dial.
  defp on_msg({:share_peers, peers}, state) do
    record_candidates(peers, state)
    state
  end

  # The peer asked US to share — reply honestly with the peers we know (bounded by amount).
  defp on_msg({:share_request, amount}, state) do
    known =
      if store_running?() do
        Cardamom.ChainStore.known_peers()
        |> Enum.take(amount)
        |> Enum.map(&%{host: &1.host, port: &1.port})
      else
        []
      end

    Cardamom.Connection.send_frame(state.conn, @peer_sharing, Codec.encode({:share_peers, known}))
    state
  end

  defp on_msg(:done, state), do: state
  defp on_msg(_other, state), do: state

  # Record each shared address as a low-trust candidate (event :peer_shared = neutral
  # delta — known but no reputation gain). It becomes dial-eligible only via the (future)
  # trust layer. We NEVER dial here. Best-effort: no store running ⇒ just observe + log.
  defp record_candidates(peers, %{peer: label}) do
    Enum.each(peers, fn %{host: host, port: port} ->
      if store_running?(), do: Cardamom.ChainStore.record_peer(%{host: host, port: port, event: :peer_shared})

      :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{
        protocol: "peer_sharing",
        msg: "PeerShared",
        host: host,
        port: port
      })
    end)

    Logger.info("peer_sharing #{label}: recorded #{length(peers)} candidate(s) (NOT dialed)")
  end

  defp store_running?, do: Process.whereis(Cardamom.Store.Repo) != nil
end
