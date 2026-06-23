defmodule Cardamom.Store.CachedTest do
  @moduledoc """
  The transferable Nebulex + SQLite read-through pattern. Every store plugs into this so
  caching is STRUCTURAL (you get it by using the abstraction), not hand-copied per table
  (which is how mempool edges ended up uncached). Two shapes:

    * PK-keyed ROW   — get/put/invalidate one entity by its primary key (header, txo, …).
    * list-by-KEY    — get a LIST by a secondary key (edges by input), with per-key
                       invalidation when a member is added/removed (one-to-many).

  Tested against the real Cache + Repo using the Txo schema (a convenient real table).
  """
  use Cardamom.DataCase, async: false
  import Ecto.Query

  alias Cardamom.Store.{Cached, Txo, Repo}

  # A PK-keyed view of the txos table: key = {txid, ix}.
  defp txo_store do
    Cached.new(
      schema: Txo,
      cache_tag: :ctest_txo,
      key_fields: [:txid, :ix]
    )
  end

  describe "PK-keyed row" do
    test "get/2 is a read-through: miss hits SQLite, then the cache serves it" do
      s = txo_store()
      {:ok, _} = Repo.insert(%Txo{txid: <<1::256>>, ix: 0, value: 42})

      # First get: not cached → read-through from SQLite.
      assert %Txo{value: 42} = Cached.get(s, {<<1::256>>, 0})
      # It's now cached: delete the DB row, the cache still serves it (proves the hit).
      Repo.delete_all(Txo)
      assert %Txo{value: 42} = Cached.get(s, {<<1::256>>, 0}), "second get is a cache hit"
    end

    test "put/2 write-through: stored AND cached" do
      s = txo_store()
      {:ok, _} = Cached.put(s, %Txo{txid: <<2::256>>, ix: 0, value: 7})
      # In SQLite...
      assert Repo.get_by(Txo, txid: <<2::256>>, ix: 0).value == 7
      # ...and served from cache without a DB read (delete row, still served).
      Repo.delete_all(Txo)
      assert %Txo{value: 7} = Cached.get(s, {<<2::256>>, 0})
    end

    test "invalidate/2 drops the cache entry so the next get re-reads" do
      s = txo_store()
      {:ok, _} = Cached.put(s, %Txo{txid: <<3::256>>, ix: 0, value: 1})
      _ = Cached.get(s, {<<3::256>>, 0})

      # Mutate the DB directly, then invalidate → next get sees the new value.
      Repo.update_all(Txo, set: [value: 999])
      Cached.invalidate(s, {<<3::256>>, 0})
      assert %Txo{value: 999} = Cached.get(s, {<<3::256>>, 0})
    end

    test "a genuine miss returns nil and is NOT cached" do
      s = txo_store()
      assert Cached.get(s, {<<9::256>>, 0}) == nil
      # Insert it, get again — must see it (negative result wasn't pinned).
      {:ok, _} = Repo.insert(%Txo{txid: <<9::256>>, ix: 0, value: 5})
      assert %Txo{value: 5} = Cached.get(s, {<<9::256>>, 0})
    end
  end

  describe "list-by-secondary-key (the edge-index shape)" do
    # Treat txos as a list keyed by VALUE (a stand-in secondary key) just to exercise the
    # one-to-many caching mechanics against a real table.
    defp by_value_store do
      Cached.new_list(
        cache_tag: :ctest_byval,
        load: fn v -> Repo.all(from t in Txo, where: t.value == ^v) end
      )
    end

    test "get_list read-through caches the list; invalidate_key re-reads" do
      import Ecto.Query
      s = by_value_store()
      {:ok, _} = Repo.insert(%Txo{txid: <<10::256>>, ix: 0, value: 100})

      assert [%Txo{txid: <<10::256>>}] = Cached.get_list(s, 100)
      # Cached now: add another row with the same value, but it won't show until invalidate.
      {:ok, _} = Repo.insert(%Txo{txid: <<11::256>>, ix: 0, value: 100})
      assert length(Cached.get_list(s, 100)) == 1, "stale cached list until invalidated"

      Cached.invalidate_key(s, 100)
      assert length(Cached.get_list(s, 100)) == 2, "re-read after invalidation"
    end
  end
end
