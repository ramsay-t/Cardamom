defmodule Cardamom.PeerSharing.ClientTest do
  @moduledoc """
  PeerSharing (proto 10) client. OBSERVE-DON'T-ACT: on start we ask a peer for
  addresses (MsgShareRequest), decode the reply (MsgSharePeers), and RECORD each as a
  low-trust candidate via ChainStore (peers are chain data) — but NEVER dial them
  (dialing is the trust layer's job, not built). We DO participate honestly: if the peer
  asks US to share, we reply with what we know. Driven over a bearer with scripted
  proto-10 messages.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{Channel, Connection, ChainStore, Mux.Frame}
  alias Cardamom.PeerSharing.Client
  alias Cardamom.Protocol.PeerSharing.Codec, as: PS

  @peer_sharing 10

  setup do
    Process.flag(:trap_exit, true)
    # A known peer (for the share-back case) recorded in the chain store.
    :ok = ChainStore.record_peer(%{host: "203.0.113.7", port: 3001, event: :connected})
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "ps")

    {:ok, client} = Client.start_link(conn: conn, peer: "ps", request_amount: 5)

    %{peer_end: peer_end, client: client}
  end

  test "on start the client sends MsgShareRequest for the configured amount", %{peer_end: pe} do
    assert {:ok, payload, _, _} = Frame.recv_msg(pe, <<>>, 1_000)
    assert {:ok, {:share_request, 5}, ""} = PS.decode(payload)
  end

  test "received shared peers are RECORDED as candidates (but never dialed)", %{peer_end: pe} do
    {:ok, _req, _, _} = Frame.recv_msg(pe, <<>>, 1_000)

    shared = [%{host: "1.2.3.4", port: 3001}, %{host: "5.6.7.8", port: 3001}]
    :ok = Frame.send_msg(pe, @peer_sharing, PS.encode({:share_peers, shared}))

    # They land in the chain store as known candidates (quality 0 via :peer_shared) — the
    # point is they're recorded, NOT dialed; there is no dial call anywhere here.
    wait_until(fn ->
      hosts = ChainStore.known_peers() |> Enum.map(& &1.host)
      "1.2.3.4" in hosts and "5.6.7.8" in hosts
    end)
  end

  test "when the PEER asks us to share, we reply with peers we know", %{peer_end: pe} do
    {:ok, _req, _, _} = Frame.recv_msg(pe, <<>>, 1_000)

    # The peer sends US a ShareRequest; we must reply MsgSharePeers with our known set.
    :ok = Frame.send_msg(pe, @peer_sharing, PS.encode({:share_request, 10}))

    # Read frames until we see a share_peers reply (skip our own initial request already
    # drained above).
    assert {:ok, {:share_peers, peers}, _} = recv_decode(pe)
    hosts = Enum.map(peers, & &1.host)
    assert "203.0.113.7" in hosts, "we honestly share what we know"
  end

  test "a MsgDone and an undecodable payload are tolerated (no crash)", %{peer_end: pe, client: client} do
    {:ok, _req, _, _} = Frame.recv_msg(pe, <<>>, 1_000)

    :ok = Frame.send_msg(pe, @peer_sharing, PS.encode(:done))
    :ok = Frame.send_msg(pe, @peer_sharing, <<0xFF, 0xFF, 0xFF>>)
    Process.sleep(50)
    assert Process.alive?(client), "Done + garbage must not crash the client"
  end

  test "an empty share_peers reply is handled without crashing" do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "ps2")
    {:ok, c} = Client.start_link(conn: conn, peer: "ps2", request_amount: 3)
    {:ok, _req, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    :ok = Frame.send_msg(peer_end, @peer_sharing, PS.encode({:share_peers, []}))
    Process.sleep(50)
    assert Process.alive?(c)
  end

  defp recv_decode(pe, buf \\ <<>>) do
    case Frame.recv_msg(pe, buf, 1_000) do
      {:ok, payload, _sdu, rest} ->
        case PS.decode(payload) do
          {:ok, {:share_peers, _} = msg, _} -> {:ok, msg, rest}
          _ -> recv_decode(pe, rest)
        end

      other ->
        other
    end
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      tries <= 0 -> flunk("condition not met")
      fun.() -> :ok
      true -> (Process.sleep(20); wait_until(fun, tries - 1))
    end
  end
end
