defmodule Cardamom.ChainSync.PersistTest do
  @moduledoc """
  The FORWARD/write half: a header arriving over chain-sync is persisted to the
  durable store (header row + tip), so a later run can resume from it. Drives a real
  structurally-valid header through bearer + ChainSync.Client and asserts it landed
  in SQLite.
  """
  # async: false → sandbox shared mode, so the client process (not the test process)
  # can use the checked-out DB connection.
  use Cardamom.DataCase, async: false

  alias Cardamom.{Channel, Connection, Mux.Frame, ChainSync}
  alias Cardamom.Protocol.ChainSync.Codec, as: CSCodec
  alias Cardamom.Ledger.Conway.HeaderBuilder
  alias Cardamom.Store.Header

  @chain_sync 2

  test "a RollForward header is persisted to the store (row + tip)" do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "persist")
    {:ok, _cs} = ChainSync.Client.start_link(conn: conn, peer: "persist", resume: false)

    # Drain the initial RequestNext.
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1_000)

    hdr = HeaderBuilder.build(block_number: 77, slot: 7_700)
    {:ok, decoded} = Cardamom.Ledger.Conway.Header.decode(hdr.raw)

    tip = [[hdr.slot, %CBOR.Tag{tag: :bytes, value: hdr.hash}], hdr.block_number]
    :ok = Frame.send_msg(peer_end, @chain_sync, CSCodec.encode({:roll_forward, hdr.envelope, tip}))

    # The client decodes + persists asynchronously; wait for the row to appear.
    assert eventually(fn -> Repo.get(Header, decoded.hash) != nil end)

    row = Repo.get(Header, decoded.hash)
    assert row.slot == 7_700
    assert row.block_no == 77
    assert row.raw == hdr.raw, "verbatim bytes persisted"

  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
