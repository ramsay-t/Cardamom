defmodule Cardamom.LogReplayPeerTest do
  @moduledoc """
  LogReplayPeer.payloads_from_log/1 — extract the recorded chain-sync payloads from a
  session log file. The replay tooling (used by the live-replay benchmark scripts) and
  tests that pass :payloads both rely on this parse; pin it so it can't silently rot.
  """
  use ExUnit.Case, async: true

  alias Cardamom.LogReplayPeer

  test "extracts the hex payloads from chain_sync raw-payload log lines, in order" do
    path = Path.join(System.tmp_dir!(), "cardamom_replay_#{System.unique_integer([:positive])}.log")

    File.write!(path, """
    12:00:00.001 [info] connected peer=foo
    12:00:00.002 [debug] chain_sync raw payload: 8200
    12:00:00.003 [info] some other line we ignore
    12:00:00.004 [debug] chain_sync raw payload: 830102
    12:00:00.005 [warning] not a payload line
    """)

    on_exit(fn -> File.rm(path) end)

    assert LogReplayPeer.payloads_from_log(path) == [<<0x82, 0x00>>, <<0x83, 0x01, 0x02>>]
  end

  test "a log with no payload lines yields an empty list" do
    path = Path.join(System.tmp_dir!(), "cardamom_replay_empty_#{System.unique_integer([:positive])}.log")
    File.write!(path, "12:00:00.001 [info] nothing to see here\n")
    on_exit(fn -> File.rm(path) end)

    assert LogReplayPeer.payloads_from_log(path) == []
  end
end
