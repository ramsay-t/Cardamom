defmodule Cardamom.ConnectionTerminateTest do
  @moduledoc """
  OTP-native shutdown behaviour after the bearer/protocol split. The polite chain-
  sync `MsgDone` now belongs to the ChainSync.Client's terminate/2 (sent via the
  bearer, which is still alive because the client is stopped first):
    * clean exit (:shutdown / :normal)  -> MsgDone on chain-sync, then the bearer closes.
    * abnormal exit (a crash/error)     -> do NOT send MsgDone; just release.
  The bearer itself only owns the socket; it traps exits so it unwinds cleanly.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Cardamom.{Channel, ChainSync, Connection, Mux.Frame}
  alias Cardamom.Protocol.ChainSync.Codec, as: CS

  @chain_sync 2

  setup do
    # We GenServer.stop / Process.exit linked processes; trap exits so their exit
    # signals don't take the test process down.
    Process.flag(:trap_exit, true)
    :ok
  end

  # Drain whatever is sent to `peer_end`, collecting decoded chain-sync messages,
  # until `timeout` of silence.
  defp collect_chain_sync(peer_end, acc \\ [], buf \\ <<>>) do
    case Frame.recv_msg(peer_end, buf, 200) do
      {:ok, payload, %{protocol_num: @chain_sync}, rest} ->
        case CS.decode(payload) do
          {:ok, msg, _} -> collect_chain_sync(peer_end, [msg | acc], rest)
          _ -> collect_chain_sync(peer_end, acc, rest)
        end

      {:ok, _payload, _sdu, rest} ->
        collect_chain_sync(peer_end, acc, rest)

      {:error, _} ->
        Enum.reverse(acc)
    end
  end

  defp start_stack(label) do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: label)
    {:ok, cs} = ChainSync.Client.start_link(conn: conn, peer: label, resume: false)
    # Let the client send its initial RequestNext.
    {:ok, _, _, _} = Frame.recv_msg(peer_end, <<>>, 1000)
    {conn, cs, peer_end}
  end

  test "clean shutdown of the chain-sync client sends MsgDone (via the live bearer)" do
    {_conn, cs, peer_end} = start_stack("clean")

    # Commanded clean stop of the protocol client — the bearer is still up to write it.
    :ok = GenServer.stop(cs, :shutdown)

    msgs = collect_chain_sync(peer_end)
    assert :done in msgs, "expected chain-sync MsgDone on clean shutdown, got #{inspect(msgs)}"
  end

  test "abnormal exit does NOT send MsgDone (just releases)" do
    {_conn, cs, peer_end} = start_stack("crash")

    Process.exit(cs, :boom)

    msgs = collect_chain_sync(peer_end)
    refute :done in msgs, "must NOT send MsgDone on abnormal exit, got #{inspect(msgs)}"
  end

  test "the chain-sync client traps exits (so terminate/2 runs on shutdown paths)" do
    {_conn, cs, _peer_end} = start_stack("trap")
    assert {:trap_exit, true} = Process.info(cs, :trap_exit)
  end

  test "the bearer traps exits (so terminate/2 releases the socket)" do
    {client_end, _peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "trap")
    assert {:trap_exit, true} = Process.info(conn, :trap_exit)
  end
end
