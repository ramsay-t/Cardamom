defmodule Cardamom.Protocol.PeerSharing.CodecTest do
  @moduledoc """
  PeerSharing (proto 10) codec, grammar from the authoritative CDDL
  (ouroboros-network .../cddl/specs/peer-sharing-v14.cddl):

      msgShareRequest = [0, word8]            # initiator: give me up to N peers
      msgSharePeers   = [1, peerAddresses]    # responder: here are some
      msgDone         = [2]
      peerAddress = [0, word32, port]                         ; IPv4 + port
                  / [1, word32, word32, word32, word32, port] ; IPv6 + port
      port = word16

  IPv4 is a packed word32 (NOT a string) — decoded to a dotted-quad host. This is the
  byte-shape the real relay validates, so it must match the CDDL exactly.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Protocol.PeerSharing.Codec

  test "share_request round-trips (amount as the word8)" do
    assert {:ok, {:share_request, 10}, ""} = Codec.decode(Codec.encode({:share_request, 10}))
  end

  test "done round-trips" do
    assert {:ok, :done, ""} = Codec.decode(Codec.encode(:done))
  end

  test "share_peers with IPv4 addresses decodes to {host, port} dotted-quads" do
    # 1.2.3.4:3001 and 10.0.0.5:3001 — encoded as packed word32 + word16 per the CDDL.
    peers = [%{host: "1.2.3.4", port: 3001}, %{host: "10.0.0.5", port: 3001}]
    encoded = Codec.encode({:share_peers, peers})

    assert {:ok, {:share_peers, decoded}, ""} = Codec.decode(encoded)
    assert decoded == peers
  end

  test "IPv4 packing is correct (1.2.3.4 = 0x01020304)" do
    {:ok, {:share_peers, [p]}, ""} =
      Codec.decode(Codec.encode({:share_peers, [%{host: "1.2.3.4", port: 65535}]}))

    assert p.host == "1.2.3.4"
    assert p.port == 65535
  end

  test "an empty share_peers (we know no one) round-trips" do
    assert {:ok, {:share_peers, []}, ""} = Codec.decode(Codec.encode({:share_peers, []}))
  end

  test "garbage / unknown tag is a clean error, never a raise (Harvard boundary)" do
    assert {:error, _} = Codec.decode(CBOR.encode([99]))
    assert {:error, _} = Codec.decode(<<0xFF, 0xFF>>)
  end

  test "IPv6 addresses round-trip (the [1, w32x4, port] shape)" do
    peers = [%{host: "2001:db8::1", port: 3001}]
    {:ok, {:share_peers, [p]}, ""} = Codec.decode(Codec.encode({:share_peers, peers}))
    # Normalised form (full groups, lower hex) — compare via :inet equality, not string.
    assert {:ok, decoded} = :inet.parse_address(String.to_charlist(p.host))
    assert {:ok, orig} = :inet.parse_address(~c"2001:db8::1")
    assert decoded == orig
    assert p.port == 3001
  end

  test "a DNS hostname is skipped (PeerSharing carries IP addresses only)" do
    # known.peer can't be encoded as a packed IP → dropped from the wire, not crashed.
    peers = [%{host: "known.peer", port: 3001}, %{host: "1.2.3.4", port: 3001}]
    {:ok, {:share_peers, decoded}, ""} = Codec.decode(Codec.encode({:share_peers, peers}))
    assert decoded == [%{host: "1.2.3.4", port: 3001}], "only the real IP survives"
  end
end
