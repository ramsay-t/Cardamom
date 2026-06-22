defmodule Cardamom.Network do
  @moduledoc """
  Network configuration, loaded from Cardano topology + genesis files (the same
  files a real node uses). Parameterised so Cardamom can run against any network
  whose config you feed it — we always feed it Preview, but you could point it at
  your own testnet/devnet.

  **Hard safety rail (structural, not discretionary):** this module REFUSES to
  build a config for Cardano **mainnet** (network magic 764824073), regardless of
  what file is supplied. Config-flexible for legitimate networks; mainnet
  forbidden in code. See the safety rules in docs/CLAUDE_NOTES.md — Cardamom is an
  experimental observer and must not connect to mainnet.
  """

  @mainnet_magic 764_824_073

  @type peer :: %{host: String.t(), port: non_neg_integer()}
  @type t :: %__MODULE__{
          magic: non_neg_integer(),
          bootstrap_peers: [peer()],
          security_param: non_neg_integer() | nil,
          slot_length: number() | nil,
          system_start: String.t() | nil
        }

  defstruct magic: nil,
            bootstrap_peers: [],
            security_param: nil,
            slot_length: nil,
            system_start: nil

  @doc """
  Load a network config from files.

  Options: `:topology` (path to topology.json), `:shelley_genesis` (path to
  shelley-genesis.json). Returns `{:ok, t}` or `{:error, reason}` — including
  `{:error, {:refused_mainnet, magic}}` if the genesis declares mainnet.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts) do
    with {:ok, topo} <- read_json(Keyword.fetch!(opts, :topology)),
         {:ok, gen} <- read_json(Keyword.fetch!(opts, :shelley_genesis)) do
      from_params(%{
        magic: gen["networkMagic"],
        bootstrap_peers: parse_bootstrap(topo),
        security_param: gen["securityParam"],
        slot_length: gen["slotLength"],
        system_start: gen["systemStart"]
      })
    end
  end

  @doc """
  Build a config from already-parsed params, applying the mainnet guard.
  """
  @spec from_params(map()) :: {:ok, t()} | {:error, term()}
  def from_params(%{magic: @mainnet_magic}), do: {:error, {:refused_mainnet, @mainnet_magic}}

  def from_params(%{magic: magic} = p) when is_integer(magic) do
    {:ok,
     %__MODULE__{
       magic: magic,
       bootstrap_peers: Map.get(p, :bootstrap_peers, []),
       security_param: Map.get(p, :security_param),
       slot_length: Map.get(p, :slot_length),
       system_start: Map.get(p, :system_start)
     }}
  end

  def from_params(other), do: {:error, {:bad_network_params, other}}

  defp parse_bootstrap(topo) do
    (topo["bootstrapPeers"] || [])
    |> Enum.map(fn %{"address" => h, "port" => p} -> %{host: h, port: p} end)
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      {:error, reason} -> {:error, {:config_read, path, reason}}
    end
  end
end
