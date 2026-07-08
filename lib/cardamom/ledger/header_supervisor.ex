defmodule Cardamom.Ledger.HeaderSupervisor do
  @moduledoc """
  DynamicSupervisor owning one `Cardamom.Ledger.HeaderHandler` per in-flight header. Mirrors
  `Cardamom.Ledger.BlockSupervisor`. A header is the CONTAINER-less unit of the receive → decode →
  validate → store pipeline: chain-sync hands each RollForward header to a handler here, which
  runs the pipeline and stores the header ONLY if it validates (so an invalid/undecodable header
  never takes DB space).

  Handlers are `restart: :temporary`: a handler exits :normal when its header is stored (or
  dropped as invalid) — a completed/failed pipeline must NOT auto-restart.
  """
  use DynamicSupervisor

  alias Cardamom.Ledger.HeaderHandler

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a handler for {era, raw, peer}. Deduped by the raw bytes' hash via the unique Registry
  name — a re-seen header returns the existing pid. `peer` is `%{host, port}` (or nil) so the
  handler can dock reputation on a validation failure. Returns `{:ok, pid}`.
  """
  def start_header(era, raw, peer \\ nil) when is_integer(era) and is_binary(raw) do
    key = :crypto.hash(:sha256, raw)

    spec = %{
      id: {:header, key},
      start: {HeaderHandler, :start_link, [{key, era, raw, peer}]},
      restart: :temporary,
      shutdown: 5_000
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Terminate ALL live handlers (test teardown)."
  def terminate_all do
    for {_id, pid, _t, _m} <- DynamicSupervisor.which_children(__MODULE__), is_pid(pid) do
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    :ok
  end
end
