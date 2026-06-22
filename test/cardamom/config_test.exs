defmodule Cardamom.ConfigTest do
  use ExUnit.Case, async: true

  alias Cardamom.Config

  # Precedence: built-in defaults  <-  config file  <-  explicit opts.

  test "defaults give Preview (magic 2, the IOG bootstrap peer, db inert)" do
    {:ok, cfg} = Config.resolve([])
    assert cfg.network == 2
    assert %{host: "preview-node.play.dev.cardano.org", port: 3001} = cfg.first_peer
    assert cfg.db == nil
  end

  test "explicit opts override defaults" do
    {:ok, cfg} = Config.resolve(first_peer: %{host: "localhost", port: 4444}, db: "test-db")
    assert cfg.first_peer == %{host: "localhost", port: 4444}
    assert cfg.db == "test-db"
    assert cfg.network == 2
  end

  test "a JSON config file is read, and opts still override it" do
    path = Path.join(System.tmp_dir!(), "cardamom_test_#{System.unique_integer([:positive])}.json")

    File.write!(path, ~s({
      "network": 2,
      "first_peer": {"host": "from-file", "port": 9999},
      "db": "file-db"
    }))

    on_exit(fn -> File.rm(path) end)

    # file beats defaults
    {:ok, cfg} = Config.resolve(config_file: path)
    assert cfg.first_peer == %{host: "from-file", port: 9999}
    assert cfg.db == "file-db"

    # explicit opts beat the file
    {:ok, cfg2} = Config.resolve(config_file: path, db: "override-db")
    assert cfg2.db == "override-db"
    assert cfg2.first_peer == %{host: "from-file", port: 9999}
  end

  test "mainnet magic is refused even via config (safety rail)" do
    assert {:error, {:refused_mainnet, 764_824_073}} = Config.resolve(network: 764_824_073)
  end

  test "a missing config file is an error (not silent)" do
    assert {:error, {:config_read, _, _}} = Config.resolve(config_file: "/no/such/file.json")
  end
end
