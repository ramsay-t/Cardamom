defmodule Cardamom.Store.Repo do
  @moduledoc """
  The durable forensic store's Ecto repo (SQLite via ecto_sqlite3).

  Ecto is used ONLY as a thin typed access layer over SQLite (and Postgres later =
  adapter swap): schemas are table shapes, changesets validate-on-insert, and we run
  inserts / gets / range queries. NO business logic lives here — the forest logic,
  validation, and lifecycle all stay in our own modules. The single reason Ecto
  beats a raw driver for us is "tables have columns": a malformed header can't be
  silently stuffed in as an arbitrary blob the way an ETS/map store would allow.

  The database file is magic-tagged (`data/forest-<magic>.db`) so Preview, PreProd,
  Mainnet, and test chains can never cross-contaminate — see `db_path/1`.
  """
  use Ecto.Repo, otp_app: :cardamom, adapter: Ecto.Adapters.SQLite3

  # The KNOWN real Cardano network magics (the canonical set). A test magic must
  # NEVER equal one of these — `safe_test_magic?/1` is the structural guarantee.
  @mainnet_magic 764_824_073
  @real_magics %{
    mainnet: 764_824_073,
    preprod: 1,
    preview: 2,
    legacy_testnet: 1_097_911_063
  }

  @doc "The canonical map of known real Cardano network magics."
  def real_magics, do: @real_magics

  @doc "Is `magic` safe to use as a TEST magic — i.e. not any known real network?"
  def safe_test_magic?(magic) when is_integer(magic),
    do: magic not in Map.values(@real_magics)

  def safe_test_magic?(_), do: false

  @doc """
  Per-network DB path, derived from the network magic (never hand-set, so it can't
  point a Preview store at a Mainnet run). `data/forest-<magic>.db`.

  Refuses mainnet outright: we don't store mainnet, so deriving its path means
  something upstream let mainnet through — fail loud rather than create the file.
  """
  def db_path(@mainnet_magic),
    do: raise(ArgumentError, "refusing to build a store path for mainnet (magic #{@mainnet_magic})")

  def db_path(magic) when is_integer(magic) and magic >= 0,
    do: Path.join(data_dir(), "forest-#{magic}.db")

  @doc """
  The base directory holding the per-network DB files. Defaults to a relative `data/`
  (fine for dev/test, cwd-relative), but in production a release sets an ABSOLUTE path
  via `config :cardamom, :data_dir` (from CARDAMOM_DATA_DIR in runtime.exs) so the chain
  DB lives OUTSIDE the swappable release dir and survives version upgrades.
  """
  def data_dir, do: Application.get_env(:cardamom, :data_dir, "data")
end
