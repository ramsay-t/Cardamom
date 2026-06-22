defmodule Cardamom.Store.Setup do
  @moduledoc """
  A one-shot supervision step that brings the durable store's SCHEMA up to date
  (runs migrations) right after the Repo starts and BEFORE any store reader
  (Forest.Server, ChainStore callers) starts.

  Placed between the Repo and the readers in the supervision tree so the ORDER
  itself guarantees "store fully prepared → then readers" — no reader needs to
  defensively check whether the schema exists. It starts, migrates, and returns
  :ignore (no lingering process; its job is done at boot).
  """
  require Logger

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker, restart: :transient}
  end

  def start_link do
    migrate()
    :ignore
  end

  defp migrate do
    path = Application.app_dir(:cardamom, "priv/repo/migrations")
    Ecto.Migrator.run(Cardamom.Store.Repo, path, :up, all: true)
  rescue
    e -> IO.warn("store migration skipped: #{inspect(e)}")
  end
end
