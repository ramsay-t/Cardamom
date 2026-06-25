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
    # data_dir: where the chain DB (forest-<magic>.db) lives. nil → the built-in default
    # ("data", relative). A params file should set an ABSOLUTE path for a deployed node.
    data_dir: nil,
    # port: the read-only HTTP UI port. nil → the app default (4001).
    port: nil,
    # log_tag: appended to the session log filename (cardamom-<ts>-<tag>.log) so a run is
    # identifiable. nil → no tag.
    log_tag: nil,
    # log_dir: where session logs are written. nil → the built-in default ("log", relative).
    # A deployed node should set an ABSOLUTE path so logs don't scatter to the launch cwd.
    log_dir: nil,
    # connect?: whether the node DIALS its boot peers on start. Default true (a deployed
    # node connects); set false for a store-only / inspection boot.
    connect: true,
    # handshake: the nodeToNodeVersionData flags we PRESENT to the relay. Defaults are the
    # conservative observer stance (initiator-only, no peer-sharing, not a version query).
    # All configurable from the params file so what we advertise is never hidden in code.
    handshake: %{initiator_only: true, peer_sharing: 0, query: false},
    protocols: [:chain_sync, :keep_alive, :block_fetch],
    # debug_raw_bytes: log the full hex of every wire payload at :debug. OFF by default — the
    # raw bytes are kept durably in the store (headers.raw etc.); these dumps are huge
    # (~38MB/2min). Turn on only for byte-level diagnosis / LogReplayPeer. See Cardamom.Debug.
    debug_raw_bytes: false,
    # fetch_bodies: proactively fetch block BODIES to catch up with headers (the metronome),
    # building the full UTxO set. Default true. Set false for a headers-only / store-light boot.
    fetch_bodies: true,
    # genesis: paths to the network's genesis files, whose initial funds seed the UTxO set
    # BEFORE block ingestion (chain blocks spend genesis UTXOs that no block produces — see
    # Cardamom.Genesis). Both eras optional/nil: a network may have only one era's funds, or
    # none configured (then nothing is seeded). Shape %{shelley: path | nil, byron: path | nil}.
    genesis: %{shelley: nil, byron: nil}
  }

  @type t :: %{
          network: non_neg_integer(),
          first_peer: %{host: String.t(), port: non_neg_integer()},
          db: String.t() | nil,
          data_dir: String.t() | nil,
          port: non_neg_integer() | nil,
          log_tag: String.t() | nil,
          log_dir: String.t() | nil,
          connect: boolean(),
          debug_raw_bytes: boolean(),
          fetch_bodies: boolean(),
          genesis: %{shelley: String.t() | nil, byron: String.t() | nil},
          handshake: %{initiator_only: boolean(), peer_sharing: 0..1, query: boolean()},
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
    |> put_if(json, "data_dir", :data_dir)
    |> put_if(json, "port", :port)
    |> put_if(json, "log_tag", :log_tag)
    |> put_if(json, "log_dir", :log_dir)
    |> put_if(json, "connect", :connect)
    |> put_if(json, "debug_raw_bytes", :debug_raw_bytes)
    |> put_if(json, "fetch_bodies", :fetch_bodies)
    |> put_genesis(json["genesis"])
    |> put_handshake(json["handshake"])
    |> put_peer(json["first_peer"])
    |> put_protocols(json["protocols"])
  end

  # handshake JSON has string keys; map the three known flags to atoms (closed set, no
  # String.to_atom). Returned as a partial map; deep_merge fills the rest from defaults.
  defp put_handshake(acc, %{} = hs) do
    flags =
      %{}
      |> maybe_flag(hs, "initiator_only", :initiator_only)
      |> maybe_flag(hs, "peer_sharing", :peer_sharing)
      |> maybe_flag(hs, "query", :query)

    if flags == %{}, do: acc, else: Map.put(acc, :handshake, flags)
  end

  defp put_handshake(acc, _), do: acc

  # genesis JSON has string keys; map the two known era paths to atoms (closed set, no
  # String.to_atom). Returned as a partial map; deep_merge fills the rest from defaults.
  defp put_genesis(acc, %{} = g) do
    paths =
      %{}
      |> maybe_flag(g, "shelley", :shelley)
      |> maybe_flag(g, "byron", :byron)

    if paths == %{}, do: acc, else: Map.put(acc, :genesis, paths)
  end

  defp put_genesis(acc, _), do: acc

  defp maybe_flag(into, src, str_key, atom_key) do
    case Map.fetch(src, str_key) do
      {:ok, v} -> Map.put(into, atom_key, v)
      :error -> into
    end
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
    Map.new(Keyword.take(opts, [:network, :first_peer, :db, :data_dir, :port, :log_tag, :log_dir, :connect, :debug_raw_bytes, :fetch_bodies, :genesis, :handshake, :protocols]))
  end

  # Merge override onto base, deep-merging the nested :handshake map so a partial file
  # (e.g. just peer_sharing) keeps the other handshake defaults.
  defp deep_merge(base, override) do
    Map.merge(base, override, fn
      :handshake, b, o when is_map(b) and is_map(o) -> Map.merge(b, o)
      :genesis, b, o when is_map(b) and is_map(o) -> Map.merge(b, o)
      _k, _b, o -> o
    end)
  end

  defp guard_mainnet(%{network: @mainnet_magic}), do: {:error, {:refused_mainnet, @mainnet_magic}}
  defp guard_mainnet(cfg), do: {:ok, cfg}
end
