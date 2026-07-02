defmodule Cardamom.Ledger.BlockSupervisor do
  @moduledoc """
  DynamicSupervisor owning one `Cardamom.Ledger.BlockHandler` per IN-FLIGHT block (a block whose
  TXOs are still being extracted). A block is a CONTAINER of txs; its handler spawns one retrier
  per tx (see BlockHandler / TxRetrier). Mirrors `Cardamom.PeerSupervisor`.

  Handlers are `restart: :temporary`: a handler EXITS :normal when its block is fully done, and a
  crash/rollback-kill must NOT auto-restart it (the reconciler re-spawns crashed ones on its tick;
  a rollback-killed handler's block is orphaned and must stay dead). So we never want the
  DynamicSupervisor to restart a handler itself.
  """
  use DynamicSupervisor

  alias Cardamom.Ledger.{BlockHandler, BlockRegistry}

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a block handler for {hash, raw, slot}, or return the existing one if a handler for this
  hash is already live (dedupe via the unique Registry name — re-extracting a block whose handler
  is still retrying is a no-op). Returns `{:ok, pid}`.
  """
  def start_block(hash, raw, slot) when is_binary(hash) and is_binary(raw) do
    spec = %{
      id: {:block, hash},
      start: {BlockHandler, :start_link, [{hash, raw, slot}]},
      restart: :temporary,
      # Generous window: terminate/2 kills tx retriers, CONFIRMS them dead, then cleans the DB.
      shutdown: 10_000
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Terminate a live handler by hash. SYNCHRONOUS: DynamicSupervisor.terminate_child blocks until the
  handler's terminate/2 returns — so on return, that block's kill-confirm-then-clean has fully
  committed. No live handler for the hash → :ok (already-completed block; the caller's bulk
  slot-sweep backstop covers it).
  """
  def terminate_block(hash) when is_binary(hash) do
    case Registry.lookup(BlockRegistry, hash) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  @doc "Terminate ALL live handlers (test teardown — stop continuous retriers leaking across tests)."
  def terminate_all do
    for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(__MODULE__), is_pid(pid) do
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    :ok
  end
end
