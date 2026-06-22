import Config

# File logging uses the built-in Erlang :logger file handler (:logger_std_h) — no
# external dependency. The handler is attached at runtime in Application.start
# (NOT here), because each session gets its OWN timestamped file
# (log/cardamom-<timestamp>[-<name>].log) — that filename can only be computed at
# boot, and a static config path would force every session into one file. See
# Cardamom.Application.attach_file_logger/0.

# Default level :debug — capture EVERYTHING (incl. raw header/block hex, which we
# log at :debug behind a lazy fn). Storage is cheap (~MBs for our runs; ~30GB/yr
# even logging full blocks); lost data is expensive (cf. the header_bytes:nil
# debugging cost). For a sustained/production run, set :info (raw bytes are then
# suppressed at ~zero cost) or compile_time_purge_matching them out entirely.
config :logger, level: :debug

# Console keeps structured metadata so live (iex) output matches the file.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:peer, :protocol, :msg, :slot, :version, :header_hash, :header_slot, :header_block]

# Durable forensic store (Ecto + SQLite). The DB FILE is magic-tagged at runtime
# (Cardamom.Store.Repo.db_path/1) so per-network stores can't cross-contaminate;
# the static default here is a placeholder the Application overrides on boot.
config :cardamom, ecto_repos: [Cardamom.Store.Repo]
# The build env, readable at runtime (Application.compile_env), so boot logic can tell
# test (throwaway tmp DB) from a real run (magic-tagged forest-<magic>.db).
config :cardamom, :env, config_env()

# pool_size: 1 — SQLite is single-writer, so the BEAM-native answer is ONE writer
# connection with db_connection queuing all callers behind it (Erlang processes
# queue cleanly). A larger pool would open multiple OS-level SQLite handles to one
# file that can only CONTEND (SQLite locks below the VM, returning "database is
# locked" rather than queuing) — never benefit. WAL lets reads proceed alongside.
config :cardamom, Cardamom.Store.Repo,
  database: Path.join("data", "forest-dev.db"),
  journal_mode: :wal,
  pool_size: 1

# Hot working-set cache (Nebulex, ETS-backed). Eviction is harmless — bytes live in
# SQLite. GC interval bounds the cache; Preview-scale fits with no hard cap.
config :cardamom, Cardamom.Store.Cache, gc_interval: :timer.hours(12)

if config_env() == :test do
  # Throwaway per-RUN DB that exercises the REAL forest-<magic>.db tagging path with a
  # TEST magic provably outside the known real networks, in a tmp data dir, on a path
  # verified not to already exist, deleted after the suite (test_helper). So the test
  # store is shaped exactly like a production store (forest-<magic>.db) yet can never
  # collide with mainnet/preprod/preview/legacy. Tests isolate via clean-slate
  # (Cardamom.DataCase); prod single-writer model (pool_size: 1).
  real_magics = [764_824_073, 1, 2, 1_097_911_063]

  # A high test magic, varied per run, guaranteed not to be a real one.
  test_magic =
    Stream.iterate(900_000_000 + rem(System.unique_integer([:positive]), 1_000_000), &(&1 + 1))
    |> Enum.find(&(&1 not in real_magics))

  test_dir = Path.join(System.tmp_dir!(), "cardamom-test-store-#{System.unique_integer([:positive])}")

  fresh_db =
    Stream.iterate(test_magic, &(&1 + 1))
    |> Stream.map(fn m -> Path.join(test_dir, "forest-#{m}.db") end)
    |> Enum.find(fn p -> not File.exists?(p) end)

  config :cardamom, Cardamom.Store.Repo,
    database: fresh_db,
    journal_mode: :wal,
    busy_timeout: 5_000,
    pool_size: 1
end
