defmodule Cardamom.Store.PeersTest do
  @moduledoc """
  Peer reputation, now plain functions on ChainStore over the shared chain DB (peers belong
  to THIS chain — same magic, same SQLite — so they're chain data, not a separate store).
  record_peer/1 moves a peer's `quality` by a per-event delta so reputation MEANS something;
  known_peers/0 ranks best-first. (Migrated from the old PeerStore.Sql tests.)
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore

  defp quality_of(host) do
    ChainStore.known_peers() |> Enum.find(&(&1.host == host)) |> Map.get(:quality)
  end

  test "a recorded peer becomes known" do
    :ok = ChainStore.record_peer(%{host: "1.2.3.4", port: 3001, event: :connected})
    assert "1.2.3.4" in (ChainStore.known_peers() |> Enum.map(& &1.host))
  end

  test "a clean session raises quality; a failure lowers it" do
    p = %{host: "5.6.7.8", port: 3001}
    :ok = ChainStore.record_peer(Map.put(p, :event, :connected))
    after_connect = quality_of("5.6.7.8")
    assert after_connect > 0, "a clean connect raises quality above the 0 baseline"

    :ok = ChainStore.record_peer(Map.put(p, :event, :timeout))
    assert quality_of("5.6.7.8") < after_connect, "a timeout lowers quality"
  end

  test "a protocol violation is penalised harder than a timeout; an invalid-tx in between" do
    base = %{port: 3001, event: :connected}
    :ok = ChainStore.record_peer(Map.merge(base, %{host: "a"}))
    :ok = ChainStore.record_peer(Map.merge(base, %{host: "b"}))
    :ok = ChainStore.record_peer(Map.merge(base, %{host: "c"}))

    :ok = ChainStore.record_peer(%{host: "a", port: 3001, event: :timeout})
    :ok = ChainStore.record_peer(%{host: "b", port: 3001, event: :sent_invalid_tx})
    :ok = ChainStore.record_peer(%{host: "c", port: 3001, event: :protocol_violation})

    # timeout (-5) > sent_invalid_tx (-10) > protocol_violation (-25): c lowest, a highest.
    assert quality_of("c") < quality_of("b")
    assert quality_of("b") < quality_of("a")
  end

  test "known_peers ranks by quality, best first" do
    :ok = ChainStore.record_peer(%{host: "good", port: 3001, event: :connected})
    :ok = ChainStore.record_peer(%{host: "good", port: 3001, event: :clean_close})
    :ok = ChainStore.record_peer(%{host: "bad", port: 3001, event: :protocol_violation})

    hosts = ChainStore.known_peers() |> Enum.map(& &1.host)
    assert Enum.find_index(hosts, &(&1 == "good")) < Enum.find_index(hosts, &(&1 == "bad"))
  end

  test ":peer_shared is neutral — registers the peer without changing its rank" do
    :ok = ChainStore.record_peer(%{host: "candidate", port: 3001, event: :peer_shared})
    assert quality_of("candidate") == 0, "a shared candidate is known but earns no reputation"
  end

  test "reputation PERSISTS in the chain DB (durable, hot-start)" do
    :ok = ChainStore.record_peer(%{host: "9.9.9.9", port: 3001, event: :connected})
    q = quality_of("9.9.9.9")
    # It's a row in the shared SQLite — a fresh read sees it.
    assert Cardamom.Store.Repo.get_by(Cardamom.Store.Peer, host: "9.9.9.9", port: 3001).quality == q
  end
end
