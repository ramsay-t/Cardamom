defmodule Cardamom.PeerStore.SqlTest do
  @moduledoc """
  The DURABLE peer store: a second PeerStore implementation backed by Ecto/SQLite (vs
  the in-memory Static). Same behaviour contract, plus the substantive part — `record`
  moves a peer's `quality` by a per-event DELTA, so reputation actually means something
  (good behaviour raises rank, bad lowers it). Persists across restarts (the point of a
  durable peers table — hot-start from last-known-good).
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.PeerStore
  alias Cardamom.PeerStore.Sql

  setup do
    {:ok, store} = Sql.start_link(bootstrap: [%{host: "boot.example", port: 3001}])
    %{store: store}
  end

  test "a recorded peer becomes known", %{store: store} do
    :ok = PeerStore.record(store, %{host: "1.2.3.4", port: 3001, event: :connected})
    hosts = PeerStore.list_known(store) |> Enum.map(& &1.host)
    assert "1.2.3.4" in hosts
  end

  test "bootstrap_peers returns the cold-start fallback", %{store: store} do
    assert [%{host: "boot.example", port: 3001}] = PeerStore.bootstrap_peers(store)
  end

  describe "reputation moves on events (the substantive bit)" do
    test "a clean session raises quality; a failure lowers it", %{store: store} do
      p = %{host: "5.6.7.8", port: 3001}

      :ok = PeerStore.record(store, Map.put(p, :event, :connected))
      after_connect = quality_of(store, "5.6.7.8")
      assert after_connect > 0, "a clean connect must raise quality above the 0 baseline"

      :ok = PeerStore.record(store, Map.put(p, :event, :timeout))
      assert quality_of(store, "5.6.7.8") < after_connect, "a timeout must lower quality"
    end

    test "a protocol violation is penalised harder than a timeout", %{store: store} do
      base = %{port: 3001, event: :connected}
      :ok = PeerStore.record(store, Map.merge(base, %{host: "a"}))
      :ok = PeerStore.record(store, Map.merge(base, %{host: "b"}))

      :ok = PeerStore.record(store, %{host: "a", port: 3001, event: :timeout})
      :ok = PeerStore.record(store, %{host: "b", port: 3001, event: :protocol_violation})

      assert quality_of(store, "b") < quality_of(store, "a"),
             "a protocol violation must cost more reputation than a timeout"
    end

    test "list_known ranks by quality, best first", %{store: store} do
      :ok = PeerStore.record(store, %{host: "good", port: 3001, event: :connected})
      :ok = PeerStore.record(store, %{host: "good", port: 3001, event: :clean_close})
      :ok = PeerStore.record(store, %{host: "bad", port: 3001, event: :protocol_violation})

      hosts = PeerStore.list_known(store) |> Enum.map(& &1.host)
      assert Enum.find_index(hosts, &(&1 == "good")) < Enum.find_index(hosts, &(&1 == "bad"))
    end
  end

  test "quality PERSISTS across a store restart (durable, hot-start)", %{store: store} do
    :ok = PeerStore.record(store, %{host: "9.9.9.9", port: 3001, event: :connected})
    q1 = quality_of(store, "9.9.9.9")

    # Stop and restart a fresh Sql store over the SAME (DataCase) repo — the row stays.
    GenServer.stop(elem(store, 1))
    {:ok, store2} = Sql.start_link(bootstrap: [])

    assert quality_of(store2, "9.9.9.9") == q1, "reputation survives restart (it's in SQLite)"
  end

  defp quality_of(store, host) do
    PeerStore.list_known(store) |> Enum.find(&(&1.host == host)) |> Map.get(:quality)
  end
end
