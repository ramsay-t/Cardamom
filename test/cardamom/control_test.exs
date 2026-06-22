defmodule Cardamom.ControlTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Cardamom.Control

  test "status reports peers (empty when none / Peers absent)" do
    # Control is started by the app; status should return a well-formed snapshot.
    s = Control.status()
    assert is_list(s.peers)
    assert is_integer(s.peer_count)
  end

  test "disconnect_all with no peer supervisor wired is a graceful no-op" do
    {:ok, ctrl} = Control.start_link(peer_supervisor: nil, name: :ctrl_no_sup)
    assert {:ok, 0} = GenServer.call(ctrl, :disconnect_all)
    GenServer.stop(ctrl)
  end

  test "status with no peer supervisor still returns a well-formed snapshot" do
    {:ok, ctrl} = Control.start_link(peer_supervisor: nil, name: :ctrl_status)
    s = GenServer.call(ctrl, :status)
    assert is_list(s.peers)
    assert is_integer(s.peer_count)
    GenServer.stop(ctrl)
  end

  test "disconnect_all gracefully terminates peer subtrees via the supervisor" do
    # A throwaway DynamicSupervisor standing in for the peer supervisor, with a
    # couple of trivial children to terminate.
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    {:ok, _c1} = DynamicSupervisor.start_child(sup, %{id: :a, start: {Agent, :start_link, [fn -> 1 end]}})
    {:ok, _c2} = DynamicSupervisor.start_child(sup, %{id: :b, start: {Agent, :start_link, [fn -> 2 end]}})

    {:ok, ctrl} = start_supervised({Control, [peer_supervisor: sup, name: :ctrl_test]}, id: :ctrl_test)
    # Call the instance directly (the named one is the app's).
    assert {:ok, 2} = GenServer.call(ctrl, :disconnect_all)
    assert DynamicSupervisor.which_children(sup) == []
  end
end
