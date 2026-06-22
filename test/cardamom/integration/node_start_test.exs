defmodule Cardamom.Integration.NodeStartTest do
  @moduledoc """
  Drives the real entry point `Cardamom.Node.start/1` against a localhost SimPeer.
  This is the proof of "same code, different params": the test calls Node.start
  with localhost params; pointing at Preview is the identical call with the
  default (or file) params. The entry point opens a real Channel.Tcp and runs the
  full handshake -> chain-sync -> keep-alive sequence.
  """
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :capture_log

  alias Cardamom.{Channel, SimPeer}

  defp capture(name) do
    test_pid = self()

    :telemetry.attach_many(
      name,
      [[:cardamom, :peer, :connected], [:cardamom, :protocol, :event]],
      fn e, m, meta, _ -> send(test_pid, {:telemetry, e, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  defp start_sim_listener do
    {:ok, lsock, port} = Channel.Tcp.listen(0)

    {:ok, acceptor} =
      Task.start_link(fn ->
        {:ok, chan} = Channel.Tcp.accept(lsock, 5_000)
        {:ok, _} = SimPeer.start_link(channel: chan, protocols: [:handshake, :chain_sync, :keep_alive, :block_fetch], magic: 2)
        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
      :gen_tcp.close(lsock)
    end)

    port
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "Node.start with localhost params runs the full sequence over real TCP" do
    capture("node-start")
    port = start_sim_listener()

    # The SAME call shape that, with default params, dials Preview.
    {:ok, _node} = Cardamom.Node.start(first_peer: %{host: "localhost", port: port}, network: 2, db: "test-db")

    assert_receive {:telemetry, [:cardamom, :peer, :connected], _, _}, 2_000
    assert_receive {:telemetry, [:cardamom, :protocol, :event], _, %{msg: "RollForward"}}, 2_000
  end

  test "Node.start refuses mainnet (safety rail at the entry point)" do
    assert {:error, {:refused_mainnet, _}} =
             Cardamom.Node.start(first_peer: %{host: "localhost", port: 1}, network: 764_824_073)
  end

  test "Node.start surfaces a connection failure cleanly (no crash)" do
    # Nothing listening on this port → connect fails → {:error, {:connect_failed,...}}.
    {:ok, lsock, port} = Channel.Tcp.listen(0)
    :gen_tcp.close(lsock)

    assert {:error, {:connect_failed, "localhost", ^port, _reason}} =
             Cardamom.Node.start(first_peer: %{host: "localhost", port: port}, network: 2)
  end
end
