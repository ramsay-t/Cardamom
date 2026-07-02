defmodule Cardamom.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    attach_file_logger()
    configure_store_db()
    ensure_store_dir()
    port = ui_port()

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
        # Block-as-container extraction: a Registry (hash -> handler pid) + a DynamicSupervisor of
        # per-block handlers, each owning one retrier process per tx. NOT skipped in :test —
        # extract_block spawns into these, and tests await handler completion. After ChainStore
        # (handlers/retriers write through it) and before anything that ingests blocks.
        Cardamom.Ledger.BlockRegistry,
        Cardamom.Ledger.BlockSupervisor,
        # Read-only observability hub (telemetry -> snapshot for the UI).
        Cardamom.Stats,
        # Read-only registry of open peer connections (network topology view).
        Cardamom.Peers,
        # The candidate-chain forest + tip pointer; fed (hash, parent) by Connection.
        Cardamom.Forest.Server,
        # Command hub: status + on-demand graceful disconnect (permanent; rediscovers
        # topology on restart). The control surface the `Cardamom` module delegates to.
        # Wire it to the PeerSupervisor so disconnect_all/0 terminates live sessions
        # (MsgDone → FIN) WITHOUT stopping the node. Shutdown is NOT Control's job — that
        # is the supervision tree's, which unwinds the same peer subtrees on stop.
        {Cardamom.Control, peer_supervisor: Cardamom.PeerSupervisor},
        # Hand-coded HTTP UI: http://localhost:#{port}
        {Bandit, plug: Cardamom.Web.Router, scheme: :http, port: port},
        # Supervises live peer sessions so they shut down GRACEFULLY (MsgDone → FIN) on
        # app stop. Before the Connector so a boot-dialed session has a home.
        Cardamom.PeerSupervisor,
        # Seed the initial UTXO set from the network's genesis files (initial funds that no
        # block produces, e.g. Preview's Byron 30B-ADA fund that block 3 spends). One-shot,
        # idempotent (UPSERT). After ChainStore (it writes through it) and BEFORE the reconciler
        # /Connector/BodyFetcher so those genesis UTXOs exist before any block spend resolves
        # against them. Skipped in :test (tests drive Genesis.load directly).
        genesis_seeder(),
        # Self-heals the TXO set: re-processes any stored block whose spends didn't fully
        # resolve (deferred-spend retriers die on restart). Boot sweep + periodic reconcile.
        # After the store is up; skipped in :test. Before the Connector so recovery runs before
        # new blocks stream in.
        reconciler(),
        # Dials the boot peer from the params file (connect: true) — what makes a RELEASE
        # actually connect. Last in the tree so the store/forest/control are up first.
        # Skipped in :test (tests dial explicitly).
        connector(),
        # The metronome: proactively fetches block BODIES to catch up with HEADERS (range
        # requests, up to 500/tick) so the full UTxO set is built. After the Connector so a
        # peer channel exists to fetch from. Config :fetch_bodies (default on); skipped in :test.
        body_fetcher()
      ]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(dev_only())

    opts = [strategy: :one_for_one, name: Cardamom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Runs AFTER our supervision tree has fully unwound (so every Session.terminate has already
  # logged its "sending MsgDone" goodbye) but while :logger is still up (kernel/logger stop
  # last, in reverse start order). Force a final fsync of our file handler so the graceful
  # teardown is durably on disk before init:stop takes the VM down. Best-effort — a missing
  # handler (e.g. it failed to attach) must not turn a clean shutdown into a crash.
  @impl true
  def stop(_state) do
    :logger_std_h.filesync(:cardamom_file)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Boot-dial the params-file peer, outside :test (tests dial explicitly).
  defp connector do
    if Application.get_env(:cardamom, :env) == :test, do: nil, else: Cardamom.Connector
  end

  # TXO self-heal sweeper, outside :test (tests drive ChainStore directly).
  defp reconciler do
    if Application.get_env(:cardamom, :env) == :test, do: nil, else: Cardamom.Reconciler
  end

  # One-shot genesis UTXO seeder, outside :test (tests drive Cardamom.Genesis.load directly).
  defp genesis_seeder do
    if Application.get_env(:cardamom, :env) == :test, do: nil, else: Cardamom.Genesis.Seeder
  end

  # Proactive body-fetch metronome. Off in :test; outside :test honour :fetch_bodies (default
  # true) so a deployment can run headers-only by setting it false.
  defp body_fetcher do
    cond do
      Application.get_env(:cardamom, :env) == :test -> nil
      Application.get_env(:cardamom, :fetch_bodies, true) == false -> nil
      true -> Cardamom.BodyFetcher
    end
  end

  # The network magic is known at BOOT (config: CARDAMOM_CONFIG file, else default =
  # Preview/2) — the SAME value we send in the handshake on connect. Bind the durable
  # store to its magic-tagged file from that one value: data/forest-<magic>.db. So
  # live chain data lands in the right per-network store and the next run resumes from
  # it; and the store's magic can't diverge from the handshake's. Mainnet refused by
  # db_path/1. In :test we keep the throwaway tmp DB from config (don't override).
  defp configure_store_db do
    unless Application.get_env(:cardamom, :env) == :test, do: configure_store_db!()
  end

  @doc """
  Bind the Repo's `database:` to the magic-tagged file under the (possibly env-set) data
  dir — the SAME binding the app does at boot. Public so release tasks (Cardamom.Release)
  point at the SAME DB the running node will, rather than the compile-time default.
  """
  def configure_store_db! do
    {:ok, cfg} = Cardamom.Config.resolve(config_opts())

    # data_dir from the params file (if set) wins — so one -p file fully locates the DB.
    if cfg.data_dir, do: Application.put_env(:cardamom, :data_dir, cfg.data_dir)

    # Surface the params-file `fetch_bodies` toggle as app env so body_fetcher/0 (which builds
    # the child spec just after this runs) sees it. Defaults true.
    Application.put_env(:cardamom, :fetch_bodies, cfg.fetch_bodies != false)
    # Same for the metronome batch size (blocks per fetch tick); BodyFetcher.init reads :body_batch.
    if cfg.body_batch, do: Application.put_env(:cardamom, :body_batch, cfg.body_batch)
    # And chain-sync pipeline depth (MsgRequestNext kept in flight); ChainSync.Client.init reads
    # :chainsync_depth. Higher hides the per-header round-trip on the single ordered channel.
    if cfg.chainsync_depth, do: Application.put_env(:cardamom, :chainsync_depth, cfg.chainsync_depth)

    path = Cardamom.Store.Repo.db_path(cfg.network)
    repo_cfg = Application.get_env(:cardamom, Cardamom.Store.Repo, [])
    Application.put_env(:cardamom, Cardamom.Store.Repo, Keyword.put(repo_cfg, :database, path))
    require Logger
    Logger.info("store: durable DB = #{path} (network magic #{cfg.network})")
    path
  end

  # UI port precedence (most specific first): app-env :ui_port (test sets 0 = ephemeral, never
  # clashes) > CARDAMOM_PORT env (the -P/--port CLI flag sets this — an explicit per-run override)
  # > params-file `port` > 4001. The env-over-file order lets `bin/cardamom-run -P 4002` run a
  # second instance without editing the file; the app-env override lets `mix test` run alongside
  # a live node.
  defp ui_port do
    cond do
      is_integer(Application.get_env(:cardamom, :ui_port)) -> Application.get_env(:cardamom, :ui_port)
      env_port = System.get_env("CARDAMOM_PORT") -> String.to_integer(env_port)
      true -> port_from_file() || 4001
    end
  end

  defp port_from_file do
    if Application.get_env(:cardamom, :env) != :test do
      case Cardamom.Config.resolve(config_opts()) do
        {:ok, %{port: p}} when is_integer(p) -> p
        _ -> nil
      end
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
    dir = log_dir()
    File.mkdir_p(dir)
    path = session_log_path(dir)

    :logger.add_handler(:cardamom_file, :logger_std_h, file_handler_config(path))

    # Pull the params-file `debug_raw_bytes` into app env so Cardamom.Debug sees it, THEN install
    # the :raw_bytes category filter (drops the huge raw-wire hex dumps unless switched on; see
    # Cardamom.Debug). Both must run AFTER the handler exists.
    if Application.get_env(:cardamom, :env) != :test do
      case Cardamom.Config.resolve(config_opts()) do
        {:ok, %{debug_raw_bytes: v}} -> Application.put_env(:cardamom, :debug_raw_bytes, v == true)
        _ -> :ok
      end
    end

    Cardamom.Debug.apply_boot_default()

    require Logger
    Logger.info("session log: #{path}")
  rescue
    # Never let a logging-setup hiccup stop the node from booting.
    e -> IO.warn("file logger not attached: #{inspect(e)}")
  end

  @doc """
  The :logger_std_h handler config for our per-session forensic file logger, for a given
  `path`. Public so a test can attach the SAME config and prove its shutdown-critical
  behaviour (no drift between what's tested and what runs).

  SHUTDOWN-CRITICAL: the graceful teardown (Session.terminate → "sending MsgDone") logs in
  the very last moments before init:stop tears the node down. The truncated-log bug was the
  handler's OVERLOAD PROTECTION: under a header flood the log queue blows past the defaults
  (drop_mode_qlen 200, flush_qlen 1000) and the handler DISCARDS messages — including the
  final teardown lines. We disable that dropping (we want a COMPLETE forensic record, not a
  live-latency-optimised one):

    * `burst_limit_enable: false` — THE decisive one: the default burst limiter caps logging to
      500 events / 1000ms and silently DROPS the rest. A header flood trips it instantly, so the
      later teardown lines vanish. Disabling it is what actually fixes the truncation.
    * `sync_mode_qlen: 0` — never buffer async; every event is written synchronously.
    * `drop_mode_qlen` / `flush_qlen` → astronomically high — never drop, never flush-discard.
    * `filesync_repeat_interval: 100` — fsync continuously, so an abrupt end loses ≤ ~100ms.

  The trade-off (a slow log sink back-pressures the node) is acceptable for an observer node
  whose whole point is the record.
  """
  def file_handler_config(path) do
    %{
      config: %{
        file: String.to_charlist(path),
        max_no_bytes: 50_000_000,
        max_no_files: 3,
        burst_limit_enable: false,
        sync_mode_qlen: 0,
        drop_mode_qlen: 1_000_000_000,
        flush_qlen: 1_000_000_000,
        filesync_repeat_interval: 100
      },
      formatter:
        Logger.Formatter.new(
          format: "$time $metadata[$level] $message\n",
          metadata: [:peer, :protocol, :msg, :slot, :version]
        )
    }
  end

  defp session_log_path(dir) do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()

    stamp =
      :io_lib.format("~4..0B~2..0B~2..0B-~2..0B~2..0B~2..0B", [y, mo, d, h, mi, s])
      |> List.to_string()

    name =
      case session_name() do
        nil -> "cardamom-#{stamp}.log"
        tag -> "cardamom-#{stamp}-#{sanitize(tag)}.log"
      end

    Path.join(dir, name)
  end

  # Log dir precedence: CARDAMOM_LOG_DIR env > params-file `log_dir` > "log" (relative).
  defp log_dir do
    from_file =
      if Application.get_env(:cardamom, :env) != :test do
        case Cardamom.Config.resolve(config_opts()) do
          {:ok, %{log_dir: d}} when is_binary(d) -> d
          _ -> nil
        end
      end

    System.get_env("CARDAMOM_LOG_DIR") || from_file || "log"
  rescue
    _ -> "log"
  end

  # Log-file tag precedence: CARDAMOM_SESSION env > :session app-env > the params file's
  # `log_tag` > none. (The file is resolved best-effort; logging must never block boot.)
  defp session_name do
    System.get_env("CARDAMOM_SESSION") || Application.get_env(:cardamom, :session) || file_log_tag()
  end

  defp file_log_tag do
    if Application.get_env(:cardamom, :env) != :test do
      case Cardamom.Config.resolve(config_opts()) do
        {:ok, %{log_tag: tag}} when is_binary(tag) -> tag
        _ -> nil
      end
    end
  rescue
    _ -> nil
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
