defmodule Cardamom.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @port String.to_integer(System.get_env("CARDAMOM_PORT", "4001"))

  @impl true
  def start(_type, _args) do
    attach_file_logger()
    configure_store_db()
    ensure_store_dir()

    children =
      [
        # Durable forensic store (SQLite via Ecto) + its hot working-set cache
        # (Nebulex), then a one-shot migration step. Ordered FIRST so the store is
        # fully prepared (started AND schema-migrated) before any reader below —
        # Forest.Server seeds itself from the stored tip in its init, so the schema
        # MUST exist by then. The order is the guarantee; readers don't check.
        Cardamom.Store.Repo,
        Cardamom.Store.Cache,
        Cardamom.Store.Setup,
        # The store's fetch-coordinator process (owns the round-robin block-fetch
        # channel list). Pure store ops don't need it; get_blocks coordination does.
        Cardamom.ChainStore,
        # Read-only observability hub (telemetry -> snapshot for the UI).
        Cardamom.Stats,
        # Read-only registry of open peer connections (network topology view).
        Cardamom.Peers,
        # The candidate-chain forest + tip pointer; fed (hash, parent) by Connection.
        Cardamom.Forest.Server,
        # Command hub: status, graceful disconnect/shutdown (permanent; rediscovers
        # topology on restart). The control surface the `Cardamom` module delegates to.
        Cardamom.Control,
        # Hand-coded HTTP UI: http://localhost:#{@port}
        {Bandit, plug: Cardamom.Web.Router, scheme: :http, port: @port}
      ] ++ dev_only()

    opts = [strategy: :one_for_one, name: Cardamom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The network magic is known at BOOT (config: CARDAMOM_CONFIG file, else default =
  # Preview/2) — the SAME value we send in the handshake on connect. Bind the durable
  # store to its magic-tagged file from that one value: data/forest-<magic>.db. So
  # live chain data lands in the right per-network store and the next run resumes from
  # it; and the store's magic can't diverge from the handshake's. Mainnet refused by
  # db_path/1. In :test we keep the throwaway tmp DB from config (don't override).
  defp configure_store_db do
    unless Application.get_env(:cardamom, :env) == :test do
      {:ok, cfg} = Cardamom.Config.resolve(config_opts())
      path = Cardamom.Store.Repo.db_path(cfg.network)
      repo_cfg = Application.get_env(:cardamom, Cardamom.Store.Repo, [])
      Application.put_env(:cardamom, Cardamom.Store.Repo, Keyword.put(repo_cfg, :database, path))
      require Logger
      Logger.info("store: durable DB = #{path} (network magic #{cfg.network})")
    end
  end

  defp config_opts do
    case System.get_env("CARDAMOM_CONFIG") do
      nil -> []
      file -> [config_file: file]
    end
  end

  # The store dir (e.g. data/) is gitignored, so a fresh checkout won't have it and
  # SQLite would fail to open the DB ("unable to open database file") — it does NOT
  # create missing parent dirs. Create the configured DB's parent dir before the Repo
  # starts. (mkdir_p is idempotent; tmp dirs already exist, so this is a no-op there.)
  defp ensure_store_dir do
    case Application.get_env(:cardamom, Cardamom.Store.Repo)[:database] do
      path when is_binary(path) -> File.mkdir_p(Path.dirname(path))
      _ -> :ok
    end
  rescue
    e -> IO.warn("store dir not created: #{inspect(e)}")
  end

  # Run any pending migrations against the durable store.

  # Per-session file logging. Each boot gets its OWN file:
  #   log/cardamom-<YYYYMMDD-HHMMSS>[-<name>].log
  # never overwritten, so sessions are distinct comparable artifacts. Optional
  # session name via CARDAMOM_SESSION env or :cardamom :session app env.
  # Attached at boot so the whole session (boot→shutdown) lands in one file.
  defp attach_file_logger do
    File.mkdir_p("log")
    path = session_log_path()

    :logger.add_handler(:cardamom_file, :logger_std_h, %{
      config: %{
        file: String.to_charlist(path),
        max_no_bytes: 50_000_000,
        max_no_files: 3
      },
      formatter:
        Logger.Formatter.new(
          format: "$time $metadata[$level] $message\n",
          metadata: [:peer, :protocol, :msg, :slot, :version]
        )
    })

    require Logger
    Logger.info("session log: #{path}")
  rescue
    # Never let a logging-setup hiccup stop the node from booting.
    e -> IO.warn("file logger not attached: #{inspect(e)}")
  end

  defp session_log_path do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()

    stamp =
      :io_lib.format("~4..0B~2..0B~2..0B-~2..0B~2..0B~2..0B", [y, mo, d, h, mi, s])
      |> List.to_string()

    case session_name() do
      nil -> "log/cardamom-#{stamp}.log"
      name -> "log/cardamom-#{stamp}-#{sanitize(name)}.log"
    end
  end

  defp session_name do
    System.get_env("CARDAMOM_SESSION") || Application.get_env(:cardamom, :session)
  end

  # Keep filenames safe: alnum, dash, underscore only.
  defp sanitize(name), do: String.replace(to_string(name), ~r/[^A-Za-z0-9_\-]/, "_")

  # DEV-ONLY loopback: a Channel.Test pair with the real Connection (parser) on
  # one end and DevFakePeer (real wire-byte generator) on the other. The whole
  # receive/parse pipeline runs for real against locally-generated traffic — only
  # the TCP socket is absent. Remove once we connect to a real relay.
  defp dev_only do
    if dev?() do
      [
        %{
          id: :dev_loopback,
          start: {__MODULE__, :start_dev_loopback, []},
          type: :supervisor
        }
      ]
    else
      []
    end
  end

  defp dev? do
    # The DevFakePeer loopback is OFF BY DEFAULT and must be opted into explicitly —
    # synthetic traffic must never contaminate a real capture by accident (it once did,
    # because the old default was "on in :dev", which is the very env `mix run` uses).
    # Turn it on ONLY with CARDAMOM_LOOPBACK=1 (or the :dev_loopback app env, e.g. set
    # true in config/test or a dev session that wants the fake relay).
    cond do
      System.get_env("CARDAMOM_LOOPBACK") in ["1", "true"] -> true
      true -> Application.get_env(:cardamom, :dev_loopback, false)
    end
  rescue
    _ -> false
  end

  @doc false
  def start_dev_loopback do
    {client_end, server_end} = Cardamom.Channel.Test.pair()

    Supervisor.start_link(
      [
        {Cardamom.Connection, name: Cardamom.Connection, channel: client_end, peer: "dev-fake-relay"},
        {Cardamom.DevFakePeer, channel: server_end}
      ],
      strategy: :one_for_all,
      name: Cardamom.DevLoopback.Supervisor
    )
  end
end
