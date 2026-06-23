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

  describe "protocols toggle (config-driven, every protocol on/off on boot)" do
    test "default protocols are the chain-following set (observational ones OFF)" do
      {:ok, cfg} = Config.resolve([])
      assert cfg.protocols == [:chain_sync, :keep_alive, :block_fetch]
      refute :peer_sharing in cfg.protocols
      refute :tx_submission in cfg.protocols
    end

    test "a JSON protocols list is parsed to known atoms" do
      path = Path.join(System.tmp_dir!(), "cardamom_proto_#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"protocols": ["chain_sync", "tx_submission", "peer_sharing"]}))
      on_exit(fn -> File.rm(path) end)

      {:ok, cfg} = Config.resolve(config_file: path)
      assert cfg.protocols == [:chain_sync, :tx_submission, :peer_sharing]
    end

    test "unknown protocol names are silently DROPPED (never String.to_atom on config)" do
      path = Path.join(System.tmp_dir!(), "cardamom_proto2_#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"protocols": ["chain_sync", "totally_made_up", "tx_submission"]}))
      on_exit(fn -> File.rm(path) end)

      {:ok, cfg} = Config.resolve(config_file: path)
      assert cfg.protocols == [:chain_sync, :tx_submission], "the bogus name is dropped, not crashed"
    end

    test "an explicit :protocols opt overrides the file/default" do
      {:ok, cfg} = Config.resolve(protocols: [:block_fetch])
      assert cfg.protocols == [:block_fetch]
    end

    test "every default protocol is one Session knows how to start" do
      {:ok, cfg} = Config.resolve([])
      known = Cardamom.Peer.Session.known_protocols()
      assert Enum.all?(cfg.protocols, &(&1 in known)), "no default protocol is unstartable"
    end
  end

  test "mainnet magic is refused even via config (safety rail)" do
    assert {:error, {:refused_mainnet, 764_824_073}} = Config.resolve(network: 764_824_073)
  end

  test "a missing config file is an error (not silent)" do
    assert {:error, {:config_read, _, _}} = Config.resolve(config_file: "/no/such/file.json")
  end
end
