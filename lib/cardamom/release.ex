defmodule Cardamom.Release do
  @moduledoc """
  Release tasks — callable from a built release WITHOUT Mix (releases don't ship Mix):

      bin/cardamom eval "Cardamom.Release.migrate()"

  The fast-restart upgrade pattern: deploy the new release alongside the old, run
  `migrate()` against the EXISTING chain DB (forward-only/additive migrations), then start
  the new release — which resumes from the stored tip and syncs only the gap. The DB lives
  at CARDAMOM_DATA_DIR (outside the release dir), so the resume point survives the upgrade.

  (The app ALSO migrates on boot via Cardamom.Store.Setup; this explicit task lets a deploy
  script migrate as a deliberate, separately-observable step before starting the node.)
  """
  @app :cardamom

  @doc "Run all pending migrations against the durable store (starts the Repo if needed)."
  def migrate do
    load_app()
    # Bind the Repo to the SAME magic-tagged DB under CARDAMOM_DATA_DIR the running node
    # uses — else migrate would hit the compile-time default and migrate the wrong file.
    Cardamom.Application.configure_store_db!()
    path = Application.app_dir(@app, "priv/repo/migrations")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Cardamom.Store.Repo, fn repo ->
        Ecto.Migrator.run(repo, path, :up, all: true)
      end)

    :ok
  end

  @doc "Roll back the durable store to migration version `version`."
  def rollback(version) do
    load_app()
    path = Application.app_dir(@app, "priv/repo/migrations")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Cardamom.Store.Repo, fn repo ->
        Ecto.Migrator.run(repo, path, :down, to: version)
      end)

    :ok
  end

  defp load_app, do: Application.load(@app)
end
