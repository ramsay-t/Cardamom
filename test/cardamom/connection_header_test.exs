defmodule Cardamom.ConnectionHeaderTest do
  @moduledoc """
  RollForward header handling: chain-sync strips the transport envelope (wrapCBORinCBOR + era tag)
  to raw header bytes and hands them to a supervised HeaderHandler, which decodes → VALIDATES →
  stores and emits the rich "HeaderStored" event (hash, slot, block, prev) — or "HeaderRejected"
  for an undecodable/invalid header. Tested with STRUCTURALLY-REAL, VALIDLY-SIGNED headers from
  HeaderBuilder (so they pass the opcert gate). The decode+emit moved from chain-sync into the
  HeaderHandler; these tests now assert on the handler's HeaderStored/HeaderRejected event.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Cardamom.{Channel, ChainSync, Connection, Mux.Frame}
  alias Cardamom.Protocol.ChainSync.Codec, as: CS
  alias Cardamom.Ledger.Conway.HeaderBuilder

  @chain_sync 2

  setup do
    Process.flag(:trap_exit, true)
    test_pid = self()
    id = "conn-header-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [[:cardamom, :protocol, :event]],
      fn _e, _m, meta, _ -> send(test_pid, {:event, meta}) end,
      nil
    )

    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "hdr")
    # The chain-sync CLIENT process owns the header handling now (it registers for
    # proto 2 with the bearer and drives RequestNext). Drain its initial RequestNext.
    {:ok, _cs} = ChainSync.Client.start_link(conn: conn, peer: "hdr", resume: false)
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1000)
    on_exit(fn -> :telemetry.detach(id) end)
    %{peer_end: peer_end}
  end

  defp roll_forward(pe, hdr) do
    tip = [[hdr.slot, %CBOR.Tag{tag: :bytes, value: hdr.hash}], hdr.block_number]
    Frame.send_msg(pe, @chain_sync, CS.encode({:roll_forward, hdr.envelope, tip}))
  end

  # REGRESSION: real Preview (2026-06-20) sends `[era, #6.24(bytes)]` — an era tag
  # then a CBOR tag-24 (wrapCBORinCBOR) around the header bytes. Our first guess
  # ([era, bytes] without tag 24) hit the fallback against the real relay. Pin the
  # real shape so it can't regress.
  test "real Preview envelope [era, tag24(bytes)] unwraps, decodes, emits real fields",
       %{peer_end: pe} do
    hdr = HeaderBuilder.build(block_number: 99, slot: 9999)
    # Wrap exactly as the real wire does: era tag, then CBOR tag 24 over the bytes.
    envelope = [4, %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: hdr.raw}}]
    tip = [[hdr.slot, %CBOR.Tag{tag: :bytes, value: hdr.hash}], hdr.block_number]
    :ok = Frame.send_msg(pe, @chain_sync, CS.encode({:roll_forward, envelope, tip}))

    # Match the HeaderHandler's HeaderStored event for THIS header specifically (slot 9999).
    expected = Base.encode16(hdr.hash, case: :lower)
    assert_receive {:event, %{msg: "HeaderStored", header_slot: 9999} = meta}, 1000
    assert meta.header_hash == expected
  end

  test "a real era-wrapped header is unwrapped, decoded, and its real fields emitted",
       %{peer_end: pe} do
    hdr = HeaderBuilder.build(block_number: 42, slot: 4242)
    :ok = roll_forward(pe, hdr)

    assert_receive {:event, %{msg: "HeaderStored", header_slot: 4242} = meta}, 1000
    assert meta.header_hash == Base.encode16(hdr.hash, case: :lower)
    assert meta.header_block == 42
    assert meta.header_bytes == byte_size(hdr.raw)
  end

  test "prev_hash is decoded and reported (chain linkage)", %{peer_end: pe} do
    parent_hash = :crypto.strong_rand_bytes(32)
    hdr = HeaderBuilder.build(block_number: 2, slot: 2, prev_hash: parent_hash)
    :ok = roll_forward(pe, hdr)

    assert_receive {:event, %{msg: "HeaderStored", header_slot: 2} = meta}, 1000
    assert meta.header_prev == Base.encode16(parent_hash, case: :lower)
  end

  test "a genesis-style header (prev_hash nil) decodes with header_prev nil", %{peer_end: pe} do
    hdr = HeaderBuilder.build(block_number: 0, slot: 0, prev_hash: nil)
    :ok = roll_forward(pe, hdr)

    assert_receive {:event, %{msg: "HeaderStored", header_slot: 0} = meta}, 1000
    assert meta.header_prev == nil
  end

  test "an undecodable header (garbage bytes in a valid envelope) is REJECTED by the handler",
       %{peer_end: pe} do
    # Well-formed transport envelope [era, tag24(bytes)] but the BYTES aren't a decodable header →
    # the handler reaches decode, fails, emits HeaderRejected (undecodable), and does NOT persist
    # it (the gate). (A non-envelope term like [1,2,3] is dropped earlier, at the network unwrap,
    # before a handler is even spawned — that's a different, chain-sync-level path.)
    garbage = <<0xA1, 0x01, 0x02>>
    env = [4, %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: garbage}}]
    :ok = Frame.send_msg(pe, @chain_sync, CS.encode({:roll_forward, env, [1, <<0::256>>]}))

    assert_receive {:event, %{msg: "HeaderRejected", rejected: :undecodable} = meta}, 1000
    refute Map.has_key?(meta, :header_hash)
  end

  test "identical real headers produce identical hashes over the wire", %{peer_end: pe} do
    hdr = HeaderBuilder.build(block_number: 5, slot: 5)
    :ok = roll_forward(pe, hdr)
    assert_receive {:event, %{msg: "HeaderStored", header_slot: 5} = m1}, 1000
    # Re-send the SAME bytes; the prior handler has exited so a fresh one spawns and re-emits.
    # Identical raw bytes → identical blake2b hash.
    :ok = roll_forward(pe, hdr)
    assert_receive {:event, %{msg: "HeaderStored", header_slot: 5} = m2}, 1000
    assert m1.header_hash == m2.header_hash
    assert m1.header_hash == Base.encode16(hdr.hash, case: :lower)
  end

  # MC/DC for unwrap_header/1 (per the pattern-matching paper): the transport envelope
  # is a DECISION with several clauses — [era, tag24(bytes)] (real Preview, covered
  # above), and these alternate shapes from SimPeer/older relays. Each clause must be
  # selected independently; a clause never taken is an untested branch even at 100%
  # line coverage. They must all decode to the SAME header.
  describe "unwrap_header/1 — alternate envelope shapes each decode" do
    test "[era, tag(:bytes)] (no wrapCBORinCBOR) decodes", %{peer_end: pe} do
      hdr = HeaderBuilder.build(block_number: 7, slot: 70)
      env = [4, %CBOR.Tag{tag: :bytes, value: hdr.raw}]
      tip = [[hdr.slot, %CBOR.Tag{tag: :bytes, value: hdr.hash}], hdr.block_number]
      :ok = Frame.send_msg(pe, @chain_sync, CS.encode({:roll_forward, env, tip}))

      assert_receive {:event, %{msg: "HeaderStored", header_slot: 70} = meta}, 1000
      assert meta.header_hash == Base.encode16(hdr.hash, case: :lower)
    end

    test "bare tag(:bytes) (no era wrapper) decodes", %{peer_end: pe} do
      hdr = HeaderBuilder.build(block_number: 8, slot: 80)
      env = %CBOR.Tag{tag: :bytes, value: hdr.raw}
      tip = [[hdr.slot, %CBOR.Tag{tag: :bytes, value: hdr.hash}], hdr.block_number]
      :ok = Frame.send_msg(pe, @chain_sync, CS.encode({:roll_forward, env, tip}))

      assert_receive {:event, %{msg: "HeaderStored", header_slot: 80} = meta}, 1000
      assert meta.header_hash == Base.encode16(hdr.hash, case: :lower)
    end
  end
end
