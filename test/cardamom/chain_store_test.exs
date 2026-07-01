defmodule Cardamom.ChainStoreTest do
  @moduledoc """
  The forensic store facade: durable SQLite (truth) fronted by a Nebulex hot cache.
  Asserts the cache/store contract that makes resume-from-tip and forensic queries
  work:
    * write-through: a put lands in BOTH cache and SQLite;
    * read-through: a get on a cache MISS reads SQLite and refills the cache;
    * eviction is harmless: an evicted-then-queried header comes back (from SQLite);
    * the tip persists (the resume point);
    * decoded forensic columns are stored alongside the raw bytes.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Store.{Cache, Header}

  defp hdr(attrs) do
    Map.merge(
      %{hash: :crypto.strong_rand_bytes(32), prev_hash: nil, slot: 1, block_no: 1, raw: <<0xAB>>},
      attrs
    )
  end

  test "put_header writes through to BOTH cache and SQLite" do
    h = hdr(%{slot: 10, block_no: 10})
    {:ok, _} = ChainStore.put_header(h)

    # In cache (no SQLite read needed)...
    assert %Header{slot: 10} = Cache.get({:header, h.hash})
    # ...and durable in SQLite.
    assert %Header{slot: 10} = Repo.get(Header, h.hash)
  end

  test "get_header on a cache MISS reads SQLite and refills the cache" do
    h = hdr(%{slot: 20})
    {:ok, _} = ChainStore.put_header(h)

    # Evict from cache → simulate the hot set having dropped it.
    Cache.delete({:header, h.hash})
    assert Cache.get({:header, h.hash}) == nil

    # get_header must still find it (read through to SQLite)...
    assert %Header{slot: 20} = ChainStore.get_header(h.hash)
    # ...and have refilled the cache so the next read is warm.
    assert %Header{slot: 20} = Cache.get({:header, h.hash})
  end

  test "get_header returns nil for an unknown hash (no negative caching)" do
    assert ChainStore.get_header(:crypto.strong_rand_bytes(32)) == nil
  end

  test "the tip persists and reads back (resume point)" do
    tip = :crypto.strong_rand_bytes(32)
    :ok = ChainStore.put_tip(tip)

    assert ChainStore.get_tip() == tip
    # And it's durable, not just cached.
    Cache.delete({:kv, "tip"})
    assert ChainStore.get_tip() == tip
  end

  test "put_decoded_header stores the forensic columns alongside the raw bytes" do
    raw = Cardamom.Ledger.Conway.HeaderBuilder.build(block_number: 7, slot: 700).raw
    {:ok, decoded} = Cardamom.Ledger.Conway.Header.decode(raw)

    {:ok, _} = ChainStore.put_decoded_header(decoded, raw)

    row = Repo.get(Header, decoded.hash)
    assert row.slot == 700
    assert row.block_no == 7
    assert row.raw == raw, "verbatim bytes kept (hash fidelity)"
    assert row.issuer_vkey == decoded.issuer_vkey, "forensic column decoded + stored"
    assert is_integer(row.protocol_major)
  end

  test "all_headers returns rows slot-ordered (forest rebuild on boot)" do
    # Assert OUR rows come back slot-ordered AMONG the results — don't assume an empty
    # store. The shared ChainStore + DataCase truncation can race with other store-heavy
    # tests, so asserting the whole list == exactly these 3 is too strong (a flake).
    {:ok, _} = ChainStore.put_header(hdr(%{hash: <<1::256>>, slot: 9_000_003}))
    {:ok, _} = ChainStore.put_header(hdr(%{hash: <<2::256>>, slot: 9_000_001}))
    {:ok, _} = ChainStore.put_header(hdr(%{hash: <<3::256>>, slot: 9_000_002}))

    ours =
      ChainStore.all_headers()
      |> Enum.map(& &1.slot)
      |> Enum.filter(&(&1 in [9_000_001, 9_000_002, 9_000_003]))

    assert ours == [9_000_001, 9_000_002, 9_000_003], "our headers come back slot-ordered"
  end

  test "resume_point returns the HIGHEST stored header, not a stale kv tip" do
    # The bug: on boot we resumed from the forest's kv tip, which could lag the stored headers
    # (stale at block 492 while headers reached 208k) → chain-sync re-streamed from near genesis.
    # resume_point must return the high-water header regardless of the kv tip.
    low = hdr(%{slot: 100, block_no: 5})
    high = hdr(%{slot: 5000, block_no: 205})
    {:ok, _} = ChainStore.put_header(low)
    {:ok, _} = ChainStore.put_header(high)

    # A STALE kv tip pointing at the LOW header (simulating an interrupted earlier run).
    :ok = ChainStore.put_tip(low.hash)

    assert [5000, hash] = ChainStore.resume_point()
    assert hash == high.hash, "resume from the highest stored header, ignoring the stale tip"
  end

  test "resume_point is nil with no stored headers (cold start → genesis)" do
    assert ChainStore.resume_point() == nil
  end
end
