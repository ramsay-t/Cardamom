defmodule Cardamom.Protocol.Handshake.ClientTest do
  use ExUnit.Case, async: true

  alias Cardamom.{Channel, SimPeer}
  alias Cardamom.Protocol.Handshake.Client

  @magic 2

  test "client and simulated peer agree a version (happy path)" do
    {client_end, server_end} = Channel.Test.pair()

    # Simulated responder: accepts v14.
    {:ok, _peer} =
      SimPeer.start_link(channel: server_end, protocols: [:handshake], accept_version: 14, magic: @magic)

    # Client proposes v14..v16, expects an accepted version back.
    assert {:ok, agreed} = Client.run(client_end, magic: @magic, versions: [14, 15, 16])
    assert agreed.version == 14
    assert agreed.version_data.network_magic == @magic
  end

  test "client surfaces a refusal" do
    {client_end, server_end} = Channel.Test.pair()

    {:ok, _peer} =
      SimPeer.start_link(channel: server_end, protocols: [:handshake], refuse: {:version_mismatch, [99]})

    assert {:error, {:refused, {:version_mismatch, [99]}}} =
             Client.run(client_end, magic: @magic, versions: [14])
  end

  test "the proposal we put on the wire declares initiator_only = true (observer role)" do
    {client_end, server_end} = Channel.Test.pair()

    {:ok, _peer} =
      SimPeer.start_link(
        channel: server_end,
        protocols: [:handshake],
        accept_version: 14,
        magic: @magic,
        report_to: self()
      )

    {:ok, _} = Client.run(client_end, magic: @magic, versions: [14])

    assert_receive {:sim_peer_received_propose, %{14 => vd}}
    assert vd.initiator_only == true
    assert vd.network_magic == @magic
  end
end
