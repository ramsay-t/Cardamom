defmodule Cardamom.ChainSync.ResumeTest do
  @moduledoc """
  The REVERSE/read half: on connect, the client consults ChainStore and resumes from
  the stored tip via FindIntersect instead of demanding from genesis. The peer then
  arbitrates (rolls us back to the shared point, forward through the real chain), so
  a dead-fork tip self-corrects without re-syncing from genesis.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{Channel, ChainStore, Connection, Mux.Frame, ChainSync}
  alias Cardamom.Protocol.ChainSync.Codec, as: CSCodec
  alias Cardamom.Ledger.Conway.HeaderBuilder

  @chain_sync 2

  defp start_stack do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "resume")
    {:ok, cs} = ChainSync.Client.start_link(conn: conn, peer: "resume")
    {conn, cs, peer_end}
  end

  test "with a stored tip, the client opens with FindIntersect (not request_next)" do
    # Seed the store with a header and mark it the tip (the forest's judged tip).
    hdr = HeaderBuilder.build(block_number: 50, slot: 5_000)
    {:ok, decoded} = Cardamom.Ledger.Conway.Header.decode(hdr.raw)
    {:ok, _} = ChainStore.put_decoded_header(decoded, hdr.raw)
    :ok = ChainStore.put_tip(decoded.hash)

    {_conn, _cs, peer_end} = start_stack()

    # First thing on the wire must be FindIntersect carrying our stored point.
    assert {:ok, payload, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    # The point's hash must go on the wire as a CBOR BYTE string (a raw binary would
    # encode as text and the relay rejects it) — so it round-trips as a tagged bytes.
    assert {:ok, {:find_intersect, [[5_000, point_hash]]}, _} = CSCodec.decode(payload)
    assert %CBOR.Tag{tag: :bytes, value: hash} = point_hash
    assert hash == decoded.hash, "offers the stored tip as the intersect point (as bytes)"
  end

  test "after IntersectFound, the client starts streaming (request_next)" do
    hdr = HeaderBuilder.build(block_number: 50, slot: 5_000)
    {:ok, decoded} = Cardamom.Ledger.Conway.Header.decode(hdr.raw)
    {:ok, _} = ChainStore.put_decoded_header(decoded, hdr.raw)
    :ok = ChainStore.put_tip(decoded.hash)

    {_conn, _cs, peer_end} = start_stack()

    # Drain the FindIntersect.
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    # Peer replies IntersectFound; client should then request_next to stream.
    point = [5_000, decoded.hash]
    tip = [[5_000, %CBOR.Tag{tag: :bytes, value: decoded.hash}], 50]
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:intersect_found, point, tip}))

    assert {:ok, payload, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert {:ok, :request_next, _} = CSCodec.decode(payload)
  end

  test "cold start (no stored tip) opens with request_next from genesis" do
    # Nothing stored → no resume point → genesis behaviour.
    {_conn, _cs, peer_end} = start_stack()

    assert {:ok, payload, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert {:ok, :request_next, _} = CSCodec.decode(payload)
  end

  test "after IntersectNotFound, the client still starts streaming (request_next)" do
    # Our stored fork is unknown to this peer — not an error; we stream from where it
    # starts us. Proves the not-found branch.
    hdr = HeaderBuilder.build(block_number: 9, slot: 900)
    {:ok, decoded} = Cardamom.Ledger.Conway.Header.decode(hdr.raw)
    {:ok, _} = ChainStore.put_decoded_header(decoded, hdr.raw)
    :ok = ChainStore.put_tip(decoded.hash)

    {_conn, _cs, peer_end} = start_stack()
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    tip = [[900, %CBOR.Tag{tag: :bytes, value: decoded.hash}], 9]
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:intersect_not_found, tip}))

    assert {:ok, payload, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert {:ok, :request_next, _} = CSCodec.decode(payload)
  end

  test "resume: false forces cold start even WITH a stored tip" do
    # The opt tests of pure message-handling use: ignore the store, go genesis.
    hdr = HeaderBuilder.build(block_number: 9, slot: 900)
    {:ok, decoded} = Cardamom.Ledger.Conway.Header.decode(hdr.raw)
    {:ok, _} = ChainStore.put_decoded_header(decoded, hdr.raw)
    :ok = ChainStore.put_tip(decoded.hash)

    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "resume")
    {:ok, _cs} = ChainSync.Client.start_link(conn: conn, peer: "resume", resume: false)

    assert {:ok, payload, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)
    assert {:ok, :request_next, _} = CSCodec.decode(payload), "resume:false → genesis despite stored tip"
  end

  test "resume_point is nil when the tip's header row is missing (tip without header)" do
    # Defensive: a tip recorded but no matching header row → no resume point (don't
    # offer a point we can't build a slot for).
    :ok = ChainStore.put_tip(:crypto.strong_rand_bytes(32))
    assert ChainStore.resume_point() == nil
  end
end
