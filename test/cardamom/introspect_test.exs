defmodule Cardamom.IntrospectTest do
  use ExUnit.Case, async: false

  alias Cardamom.Introspect

  describe "system/0" do
    test "returns a read-only VM summary with the expected keys" do
      s = Introspect.system()
      assert is_integer(s.process_count) and s.process_count > 0
      assert is_integer(s.memory_total_bytes) and s.memory_total_bytes > 0
      assert is_integer(s.run_queue) and s.run_queue >= 0
      assert is_integer(s.schedulers) and s.schedulers > 0
    end
  end

  describe "processes/1" do
    test "returns at most `limit` entries, each with health fields" do
      procs = Introspect.processes(5)
      assert length(procs) <= 5

      for p <- procs do
        assert is_binary(p.pid)
        assert is_integer(p.message_queue_len) and p.message_queue_len >= 0
        assert is_integer(p.memory_bytes) and p.memory_bytes >= 0
        assert is_integer(p.reductions) and p.reductions >= 0
        # name is a string or nil
        assert is_binary(p.name) or is_nil(p.name)
      end
    end

    test "is sorted by message_queue_len descending (spot unhealthy mailboxes first)" do
      lens = Introspect.processes(20) |> Enum.map(& &1.message_queue_len)
      assert lens == Enum.sort(lens, :desc)
    end
  end

  describe "tree/1" do
    test "walks a supervision tree into a nested map of names + children" do
      # A throwaway supervisor with one worker child.
      {:ok, sup} =
        Supervisor.start_link(
          [%{id: :probe, start: {Agent, :start_link, [fn -> :ok end]}}],
          strategy: :one_for_one
        )

      node = Introspect.tree(sup)
      assert node.type == :supervisor
      assert is_list(node.children)
      assert length(node.children) == 1
      [child] = node.children
      assert child.type in [:worker, :supervisor]

      Supervisor.stop(sup)
    end
  end

  describe "hidden?/2 — negative (default-visible) filter" do
    test "nothing is hidden by an empty pattern list" do
      refute Introspect.hidden?(~s("acceptor-1"), [])
    end

    test "matches a regex pattern against the child label" do
      patterns = [~r/^"acceptor-\d+"$/]
      assert Introspect.hidden?(~s("acceptor-42"), patterns)
      refute Introspect.hidden?("Cardamom.Stats", patterns)
    end

    test "matches a plain-string pattern as a substring" do
      assert Introspect.hidden?(~s("acceptor-7"), ["acceptor-"])
      refute Introspect.hidden?("Cardamom.PeerSupervisor", ["acceptor-"])
    end
  end

  describe "tree/2 with hide patterns" do
    test "omits children whose label matches a hide pattern, keeps the rest" do
      {:ok, sup} =
        Supervisor.start_link(
          [
            %{id: :keep_me, start: {Agent, :start_link, [fn -> :ok end]}},
            %{id: :hide_me, start: {Agent, :start_link, [fn -> :ok end]}}
          ],
          strategy: :one_for_one
        )

      node = Introspect.tree(sup, [~r/hide_me/])
      labels = Enum.map(node.children, & &1.name)
      assert Enum.any?(labels, &(&1 =~ "keep_me"))
      refute Enum.any?(labels, &(&1 =~ "hide_me"))

      Supervisor.stop(sup)
    end

    test "default_hidden/0 returns the maintained pattern list" do
      assert is_list(Introspect.default_hidden())
    end
  end
end
