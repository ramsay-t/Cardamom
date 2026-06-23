defmodule Cardamom.Config do
  @moduledoc """
  Resolves a node's runtime configuration from three layers, lowest precedence
  first: **built-in defaults ← JSON config file ← explicit opts**. So you can drop
  a config file on a server and run, while tests/iex override anything inline —
  same entry point, "localhost vs Preview is the same call with different params".

  JSON (not an Elixir config script) deliberately: a config file is data, and a
  data format cannot execute code — honouring the data-not-code boundary
  (security.md). The mainnet guard applies here too: no config can select mainnet.

  Resolved shape: `%{network: magic, first_peer: %{host:, port:}, db: path|nil}`.
  `db` is currently INERT (reserved for the persistence layer).
  """

  @mainnet_magic 764_824_073

  # Built-in defaults = Preview. `protocols` lists which mini-protocols to run on boot —
  # every protocol is independently toggleable. Default = the chain-following set; the
  # OBSERVATIONAL protocols (peer_sharing, tx_submission) are off unless config enables
  # them (observe-don't-act: turning them on is a deliberate choice).
  @defaults %{
    network: 2,
    first_peer: %{host: "preview-node.play.dev.cardano.org", port: 3001},
    db: nil,
    protocols: [:chain_sync, :keep_alive, :block_fetch]
  }

  @type t :: %{
          network: non_neg_integer(),
          first_peer: %{host: String.t(), port: non_neg_integer()},
          db: String.t() | nil,
          protocols: [atom()]
        }

  @doc "Resolve config from defaults ← file (opts[:config_file]) ← opts."
  @spec resolve(keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(opts \\ []) do
    with {:ok, from_file} <- load_file(Keyword.get(opts, :config_file)),
         merged <- @defaults |> deep_merge(from_file) |> deep_merge(opts_map(opts)),
         {:ok, cfg} <- guard_mainnet(merged) do
      {:ok, cfg}
    end
  end

  defp load_file(nil), do: {:ok, %{}}

  defp load_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      {:ok, normalise(json)}
    else
      {:error, reason} -> {:error, {:config_read, path, reason}}
    end
  end

  # JSON keys are strings; normalise the ones we know to atoms + the nested peer.
  defp normalise(json) do
    %{}
    |> put_if(json, "network", :network)
    |> put_if(json, "db", :db)
    |> put_peer(json["first_peer"])
    |> put_protocols(json["protocols"])
  end

  # protocols in JSON are strings ("chain_sync"); map to the known atoms, silently
  # dropping unknowns (never String.to_atom on config we then dispatch on — closed set).
  defp put_protocols(acc, names) when is_list(names) do
    known = Map.new(Cardamom.Peer.Session.known_protocols(), &{Atom.to_string(&1), &1})
    protocols = Enum.flat_map(names, fn n -> List.wrap(Map.get(known, n)) end)
    Map.put(acc, :protocols, protocols)
  end

  defp put_protocols(acc, _), do: acc

  defp put_if(acc, json, str_key, atom_key) do
    case Map.fetch(json, str_key) do
      {:ok, v} -> Map.put(acc, atom_key, v)
      :error -> acc
    end
  end

  defp put_peer(acc, %{"host" => h, "port" => p}), do: Map.put(acc, :first_peer, %{host: h, port: p})
  defp put_peer(acc, _), do: acc

  # opts (keyword) → only the config keys we recognise.
  defp opts_map(opts) do
    Map.new(Keyword.take(opts, [:network, :first_peer, :db, :protocols]))
  end

  defp deep_merge(base, override), do: Map.merge(base, override)

  defp guard_mainnet(%{network: @mainnet_magic}), do: {:error, {:refused_mainnet, @mainnet_magic}}
  defp guard_mainnet(cfg), do: {:ok, cfg}
end
