defmodule Cardamom.Genesis.Seeder do
  @moduledoc """
  A one-shot supervision step that seeds the initial UTXO set from the network's genesis
  files (`Cardamom.Genesis.load/1`) ONCE at boot, BEFORE the Connector/BodyFetcher start
  pulling blocks — so chain spends of genesis UTXOs resolve from the first block on.

  Placed AFTER the store (Repo + Setup migrations + ChainStore) and BEFORE the connector
  in the supervision tree, so the ORDER guarantees "store ready → genesis seeded → blocks
  ingested". Idempotent (UPSERT), so a reboot just re-seeds the same rows harmlessly. It
  seeds, then returns `:ignore` (no lingering process — its job is done at boot), exactly
  like `Cardamom.Store.Setup`.

  The genesis file paths come from the resolved config's `:genesis` map; if both are nil
  (none configured) nothing is seeded. Skipped in `:test` (tests drive `Genesis.load/1`).
  """
  require Logger

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker, restart: :transient}
  end

  def start_link do
    seed()
    :ignore
  end

  defp seed do
    with {:ok, cfg} <- Cardamom.Config.resolve(config_opts()),
         genesis when is_map(genesis) <- Map.get(cfg, :genesis, %{}),
         {:ok, _count} <- Cardamom.Genesis.load(genesis) do
      :ok
    else
      other -> Logger.warning("genesis: not seeded (#{inspect(other)})")
    end
  rescue
    e -> IO.warn("genesis seeding skipped: #{inspect(e)}")
  end

  defp config_opts do
    case System.get_env("CARDAMOM_CONFIG") do
      nil -> []
      file -> [config_file: file]
    end
  end
end
