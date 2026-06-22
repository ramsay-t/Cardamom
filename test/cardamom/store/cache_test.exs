defmodule Cardamom.Store.CacheTest do
  @moduledoc """
  Direct tests of the Nebulex cache adapter. cache.ex is macro-only (`use
  Nebulex.Cache`), so the round-trip behaviour is what we actually verify — and it
  confirms the adapter is wired correctly (a misconfigured cache would fail these).
  The cache is the hot tier in front of SQLite; eviction is harmless (bytes live in
  the durable store), so delete/expire must not error.
  """
  use ExUnit.Case, async: false

  alias Cardamom.Store.Cache

  setup do
    Cache.delete_all()
    :ok
  end

  test "put then get round-trips a value" do
    Cache.put({:header, "h1"}, %{slot: 7})
    assert Cache.get({:header, "h1"}) == %{slot: 7}
  end

  test "get on an absent key returns nil (a miss — read-through happens above, in ChainStore)" do
    assert Cache.get({:header, "nope"}) == nil
  end

  test "delete evicts (harmless — the durable store still has it)" do
    Cache.put({:kv, "tip"}, "x")
    assert Cache.get({:kv, "tip"}) == "x"
    Cache.delete({:kv, "tip"})
    assert Cache.get({:kv, "tip"}) == nil
  end

  test "delete_all clears the whole cache" do
    Cache.put({:header, "a"}, 1)
    Cache.put({:header, "b"}, 2)
    Cache.delete_all()
    assert Cache.get({:header, "a"}) == nil
    assert Cache.get({:header, "b"}) == nil
  end

  test "tuple keys with different shapes don't collide" do
    Cache.put({:header, "x"}, :hdr)
    Cache.put({:kv, "x"}, :kv)
    assert Cache.get({:header, "x"}) == :hdr
    assert Cache.get({:kv, "x"}) == :kv
  end
end
