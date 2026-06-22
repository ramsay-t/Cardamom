defmodule Cardamom.PeerStore.StaticTest do
  use ExUnit.Case, async: true

  alias Cardamom.PeerStore
  alias Cardamom.PeerStore.Static

  # The Static store is the TEST/DEV peer data layer: in-memory, seeded from a
  # fixed list, NEVER touches SQL. This is the default for tests so the test
  # suite cannot pollute real peer data.

  setup do
    seed = [
      %{host: "preview-node.play.dev.cardano.org", port: 3001, quality: 100},
      %{host: "10.0.0.5", port: 3001, quality: 50}
    ]

    {:ok, store} = Static.start_link(seed: seed, bootstrap: [%{host: "boot.example", port: 3001}])
    %{store: store}
  end

  test "list_known returns seeded peers ranked by quality (best first)", %{store: store} do
    [first, second] = PeerStore.list_known(store)
    assert first.host == "preview-node.play.dev.cardano.org"
    assert first.quality == 100
    assert second.quality == 50
  end

  test "bootstrap_peers returns the cold-start fallback set", %{store: store} do
    assert [%{host: "boot.example", port: 3001}] = PeerStore.bootstrap_peers(store)
  end

  test "record/2 adds an observation for a peer", %{store: store} do
    :ok = PeerStore.record(store, %{host: "1.2.3.4", port: 3001, event: :connected, version: 14})

    obs = PeerStore.observations(store)
    assert Enum.any?(obs, fn o -> o.host == "1.2.3.4" and o.event == :connected end)
  end

  test "a newly recorded peer becomes known (so it can be hot-started next time)", %{store: store} do
    :ok = PeerStore.record(store, %{host: "1.2.3.4", port: 3001, event: :connected, version: 14})
    hosts = PeerStore.list_known(store) |> Enum.map(& &1.host)
    assert "1.2.3.4" in hosts
  end

  test "two stores are independent (no shared/global state to pollute)" do
    {:ok, a} = Static.start_link(seed: [%{host: "a", port: 1, quality: 1}])
    {:ok, b} = Static.start_link(seed: [%{host: "b", port: 1, quality: 1}])
    assert PeerStore.list_known(a) |> Enum.map(& &1.host) == ["a"]
    assert PeerStore.list_known(b) |> Enum.map(& &1.host) == ["b"]
  end
end
