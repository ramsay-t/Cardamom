defmodule Cardamom.SimPeerTest do
  use ExUnit.Case, async: true

  # SimPeer deliberately terminates on the violation tests (by design — the real
  # node kills the connection). Capture the resulting GenServer-terminating logs
  # so the expected noise doesn't clutter test output.
  @moduletag :capture_log

  alias Cardamom.{Channel, Mux.Frame, SimPeer}
  alias Cardamom.Protocol.Handshake.Codec, as: HS
  alias Cardamom.Protocol.ChainSync.Codec, as: CS

  @handshake 0
  @chain_sync 2
  @keep_alive 8

  # SimPeer is a single-process, multi-protocol, directable test responder. It
  # ENFORCES what the real node enforces (agency, size, timeout) so passing the
  # sim means Preview-ready. Enforcement is PARAMETERISED so tests can trip each
  # failure deliberately. On a violation it reports {:closed, reason} (and stops),
  # matching the real node killing the connection.

  setup do
    # SimPeer stops abnormally on a protocol violation (by design — the real node
    # kills the connection). Trap exits so that propagating exit doesn't take the
    # test process down before it can observe the {:DOWN, ...} from its monitor.
    Process.flag(:trap_exit, true)
    :ok
  end

  defp start(opts) do
    {client, server} = Channel.Test.pair()
    {:ok, peer} = SimPeer.start_link(Keyword.put(opts, :channel, server))
    %{client: client, peer: peer}
  end

  describe "happy paths (valid sequences are accepted)" do
    test "handshake: proposing v14 is accepted" do
      %{client: c} = start(protocols: [:handshake], accept_version: 14, magic: 2)

      :ok = Frame.send_msg(c, @handshake, HS.encode({:propose_versions, %{14 => vd(2)}}))
      {:ok, payload, _, _} = Frame.recv_msg(c, <<>>, 1000)
      assert {:ok, {:accept_version, 14, _}, ""} = HS.decode(payload)
    end

    test "chain-sync: RequestNext gets a RollForward" do
      %{client: c} = start(protocols: [:chain_sync])

      :ok = Frame.send_msg(c, @chain_sync, CS.encode(:request_next))
      {:ok, payload, _, _} = Frame.recv_msg(c, <<>>, 1000)
      assert {:ok, {:roll_forward, _, _}, ""} = CS.decode(payload)
    end

    test "chain-sync: SimPeer emits a STRUCTURALLY-REAL header that our decoder decodes" do
      %{client: c} = start(protocols: [:chain_sync])

      :ok = Frame.send_msg(c, @chain_sync, CS.encode(:request_next))
      {:ok, payload, _, _} = Frame.recv_msg(c, <<>>, 1000)
      {:ok, {:roll_forward, header_envelope, _tip}, ""} = CS.decode(payload)

      # Real wire shape: [era, %CBOR.Tag{:bytes, raw}] — unwrap and decode it.
      # Real wire shape: [era, #6.24(bytes)] (CBOR tag 24 = wrapCBORinCBOR).
      [_era, %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: raw}}] = header_envelope
      assert {:ok, h} = Cardamom.Ledger.Conway.Header.decode(raw)
      assert is_integer(h.slot) and is_integer(h.block_number)
      assert byte_size(h.hash) == 32
    end

    test "chain-sync: successive SimPeer headers chain (each prev_hash = previous hash)" do
      %{client: c} = start(protocols: [:chain_sync])

      get_header = fn buf ->
        :ok = Frame.send_msg(c, @chain_sync, CS.encode(:request_next))
        {:ok, payload, _, rest} = Frame.recv_msg(c, buf, 1000)
        {:ok, {:roll_forward, [_era, %CBOR.Tag{tag: 24, value: %CBOR.Tag{value: raw}}], _}, ""} =
          CS.decode(payload)
        {:ok, h} = Cardamom.Ledger.Conway.Header.decode(raw)
        {h, rest}
      end

      {h1, rest} = get_header.(<<>>)
      {h2, _} = get_header.(rest)

      # h2 links to h1: h2.prev_hash == h1.hash (a genuinely linked chain).
      assert h2.prev_hash == h1.hash
    end

    test "chain-sync: a WELL-FORMED FindIntersect (hash as bytes, via our encoder) is accepted" do
      %{client: c} = start(protocols: [:chain_sync])

      # Our encoder wraps the point hash as a CBOR byte string — the correct shape.
      :ok = Frame.send_msg(c, @chain_sync, CS.encode({:find_intersect, [[4000, :crypto.strong_rand_bytes(32)]]}))

      {:ok, payload, _, _} = Frame.recv_msg(c, <<>>, 1000)
      assert {:ok, {:intersect_found, _, _}, ""} = CS.decode(payload)
    end
  end

  describe "rejections (SimPeer is STRICT like the real relay)" do
    test "chain-sync: a FindIntersect whose point hash is a TEXT string is REJECTED (relay closes)" do
      # This is the EXACT bug that dropped us on Preview: a raw-binary hash encodes as
      # a CBOR TEXT string, not bytes. Hand-craft that malformed point (bypassing our
      # now-correct encoder) and confirm SimPeer closes the connection — the same way
      # the real relay did. This is the test that would have caught the live failure.
      %{client: c, peer: peer} = start(protocols: [:chain_sync])
      ref = Process.monitor(peer)

      malformed = CBOR.encode([4, [[4000, "not-bytes-this-is-a-text-string"]]])
      :ok = Frame.send_msg(c, @chain_sync, malformed)

      # SimPeer judges it a protocol violation and closes (peer process stops).
      assert_receive {:DOWN, ^ref, :process, ^peer, _reason}, 1000
    end

    test "chain-sync: a well-formed FindIntersect does NOT cause a close" do
      %{client: c, peer: peer} = start(protocols: [:chain_sync])
      ref = Process.monitor(peer)

      :ok = Frame.send_msg(c, @chain_sync, CS.encode({:find_intersect, [[4000, :crypto.strong_rand_bytes(32)]]}))
      {:ok, _payload, _, _} = Frame.recv_msg(c, <<>>, 1000)

      refute_receive {:DOWN, ^ref, :process, ^peer, _}, 300
      assert Process.alive?(peer)
    end
  end

  describe "more happy paths" do
    test "keep-alive: a cookie is echoed back unchanged" do
      %{client: c} = start(protocols: [:keep_alive])

      :ok = Frame.send_msg(c, @keep_alive, keepalive_msg(0x1234))
      {:ok, payload, _, _} = Frame.recv_msg(c, <<>>, 1000)
      assert {1, 0x1234} = decode_keepalive(payload)
    end

    test "speaks several protocols over one connection" do
      %{client: c} = start(protocols: [:handshake, :chain_sync, :keep_alive], magic: 2)

      :ok = Frame.send_msg(c, @keep_alive, keepalive_msg(7))
      {:ok, ka, _, _} = Frame.recv_msg(c, <<>>, 1000)
      assert {1, 7} = decode_keepalive(ka)

      :ok = Frame.send_msg(c, @chain_sync, CS.encode(:request_next))
      {:ok, cs, _, rest} = Frame.recv_msg(c, <<>>, 1000)
      assert {:ok, {:roll_forward, _, _}, ""} = CS.decode(cs)
      _ = rest
    end
  end

  describe "AGENCY enforcement (parameterised) — out-of-turn messages close the peer" do
    test "chain-sync: client sending RollForward (a server-agency msg) is a violation" do
      %{client: c, peer: peer} = start(protocols: [:chain_sync], enforce_agency: true)
      ref = Process.monitor(peer)

      # RollForward is the SERVER's message; client sending it = no agency.
      :ok = Frame.send_msg(c, @chain_sync, CS.encode({:roll_forward, <<0>>, [1, <<0::256>>]}))

      assert_receive {:DOWN, ^ref, :process, ^peer, {:protocol_violation, _}}, 1000
    end

    test "with enforce_agency: false, the same message does NOT close (lenient mode)" do
      %{client: c, peer: peer} = start(protocols: [:chain_sync], enforce_agency: false)
      ref = Process.monitor(peer)

      :ok = Frame.send_msg(c, @chain_sync, CS.encode({:roll_forward, <<0>>, [1, <<0::256>>]}))
      refute_receive {:DOWN, ^ref, :process, ^peer, _}, 300
    end
  end

  describe "SIZE enforcement (parameterised) — oversized messages close the peer" do
    test "a payload over max_payload_bytes is a violation" do
      %{client: c, peer: peer} = start(protocols: [:chain_sync], max_payload_bytes: 16)
      ref = Process.monitor(peer)

      big = CS.encode({:roll_forward, :crypto.strong_rand_bytes(100), [1, <<0::256>>]})
      :ok = Frame.send_msg(c, @chain_sync, big)

      assert_receive {:DOWN, ^ref, :process, ^peer, {:size_limit, _}}, 1000
    end
  end

  describe "TIMEOUT enforcement (parameterised, test-scaled) — silence closes the peer" do
    test "no message within idle_timeout_ms closes the connection" do
      %{peer: peer} = start(protocols: [:chain_sync], idle_timeout_ms: 100)
      ref = Process.monitor(peer)

      # send nothing; the peer should reap us for silence
      assert_receive {:DOWN, ^ref, :process, ^peer, {:timeout, _}}, 1000
    end

    test "no idle timeout when unset (default): silence is tolerated" do
      %{peer: peer} = start(protocols: [:chain_sync])
      ref = Process.monitor(peer)
      refute_receive {:DOWN, ^ref, :process, ^peer, _}, 300
    end
  end

  # ---- helpers ----

  defp vd(magic), do: %{network_magic: magic, initiator_only: true, peer_sharing: 0, query: false}

  # KeepAlive wire shapes (mini-protocol 8): [0, cookie] / [1, cookie] / [2].
  defp keepalive_msg(cookie), do: CBOR.encode([0, cookie])

  defp decode_keepalive(payload) do
    {:ok, [key, cookie], ""} = CBOR.decode(payload)
    {key, cookie}
  end
end
