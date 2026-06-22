defmodule Cardamom.NetworkTest do
  use ExUnit.Case, async: true

  alias Cardamom.Network

  @preview_dir Path.expand("~/GoogleDrive/IOHK/preview-config")

  describe "load/1 from topology + shelley genesis files" do
    @describetag :preview_config

    setup do
      unless File.dir?(@preview_dir), do: raise("preview config dir missing: #{@preview_dir}")
      :ok
    end

    test "loads Preview network params from the saved config files" do
      {:ok, net} =
        Network.load(
          topology: Path.join(@preview_dir, "topology.json"),
          shelley_genesis: Path.join(@preview_dir, "shelley-genesis.json")
        )

      assert net.magic == 2
      assert net.security_param == 432
      assert net.slot_length == 1
      assert [%{host: "preview-node.play.dev.cardano.org", port: 3001} | _] = net.bootstrap_peers
    end
  end

  describe "mainnet guard — structural safety rail" do
    test "refuses to build a config with mainnet magic, regardless of file" do
      assert {:error, {:refused_mainnet, 764_824_073}} =
               Network.from_params(%{magic: 764_824_073, bootstrap_peers: []})
    end

    test "accepts a non-mainnet magic (e.g. a custom devnet)" do
      assert {:ok, net} =
               Network.from_params(%{
                 magic: 42,
                 bootstrap_peers: [%{host: "localhost", port: 3001}],
                 security_param: 10,
                 slot_length: 1
               })

      assert net.magic == 42
    end

    test "Preview (magic 2) is accepted" do
      assert {:ok, _} = Network.from_params(%{magic: 2, bootstrap_peers: []})
    end
  end
end
