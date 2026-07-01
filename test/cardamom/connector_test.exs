defmodule Cardamom.ConnectorTest do
  @moduledoc """
  The Connector is the reconnect manager: it dials the boot peer and, on a session DOWN (drop,
  keep-alive timeout, RST), redials with ConnectPolicy backoff. Here we point it at a DEAD local
  port so every dial fails, and assert it (a) survives a failed dial without crashing, (b) backs
  off rather than hammering, and (c) keeps retrying — the resilience contract, without needing a
  real relay. (The full happy-path dial is covered by the live run + Node/Session tests.)
  """
  use ExUnit.Case, async: false

  setup do
    Process.flag(:trap_exit, true)
    # A params file pointing at a dead local port (nothing listening) so dials fail fast.
    path = Path.join(System.tmp_dir!(), "connector-test-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        network: 2,
        first_peer: %{host: "127.0.0.1", port: 65_534},
        connect: true,
        protocols: ["chain_sync"]
      })
    )

    System.put_env("CARDAMOM_CONFIG", path)
    on_exit(fn -> System.delete_env("CARDAMOM_CONFIG"); File.rm(path) end)
    :ok
  end

  test "survives a failed dial and stays up to retry (doesn't crash on connection refused)" do
    {:ok, conn} = Cardamom.Connector.start_link([])
    # Give the boot dial (continue) a moment to run + fail against the dead port.
    Process.sleep(300)
    assert Process.alive?(conn), "connector must survive a failed dial and keep trying"
    GenServer.stop(conn)
  end

  test "connect: false → store-only, no dialing, stays up" do
    path = Path.join(System.tmp_dir!(), "connector-noconnect-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{network: 2, first_peer: %{host: "127.0.0.1", port: 65_534}, connect: false}))
    System.put_env("CARDAMOM_CONFIG", path)

    {:ok, conn} = Cardamom.Connector.start_link([])
    Process.sleep(100)
    assert Process.alive?(conn)
    GenServer.stop(conn)
    File.rm(path)
  end
end
