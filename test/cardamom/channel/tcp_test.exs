defmodule Cardamom.Channel.TcpTest do
  use ExUnit.Case, async: true

  alias Cardamom.Channel

  # Tests against a throwaway LOCAL listener — no external network. Proves the
  # socket channel satisfies the Channel behaviour, incl. {:error, :closed}.

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)
    %{listen: listen, port: port}
  end

  test "connect, send, recv round-trip", %{listen: listen, port: port} do
    server =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen)
        {:ok, bytes} = :gen_tcp.recv(sock, 0, 1_000)
        :ok = :gen_tcp.send(sock, "echo:" <> bytes)
        Process.sleep(50)
        :gen_tcp.close(sock)
      end)

    {:ok, chan} = Channel.Tcp.connect("localhost", port, 1_000)
    assert :ok = Channel.send(chan, "hello")
    assert {:ok, "echo:hello"} = Channel.recv(chan, 1_000)

    Task.await(server)
  end

  test "recv returns {:error, :closed} when the far end closes", %{listen: listen, port: port} do
    server =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen)
        :gen_tcp.close(sock)
      end)

    {:ok, chan} = Channel.Tcp.connect("localhost", port, 1_000)
    Task.await(server)

    assert {:error, :closed} = Channel.recv(chan, 1_000)
  end

  test "connect to a closed port errors cleanly" do
    # Port 1 is privileged/unused; connection should be refused, not crash.
    assert {:error, _} = Channel.Tcp.connect("localhost", 1, 500)
  end
end
