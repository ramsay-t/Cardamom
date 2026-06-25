defmodule Cardamom.Reconciler do
  @moduledoc """
  Self-heals the TXO set against stored blocks. Two jobs, one process:

    * BOOT recovery — on start, re-process any stored block whose TXOs weren't fully extracted
      (txo_processed = false). Deferred-spend retriers (spawn-and-retry in ChainStore) die with
      the VM, so a crash/restart can leave a "dangling" spend (a stored block spends a UTxO
      still marked unspent). Re-running process_block for those blocks fixes it idempotently.
    * PERIODIC reconcile — every `interval_ms`, do the same sweep, catching live misses (a
      retrier that gave up, or a block processed before its producer arrived during backfill).

  No durable pending-spend table is needed: the block's `raw` is already in the store, so a
  re-process is a free idempotent replay (UPSERT outputs + fail-fast spends). This is the
  recovery half of the BEAM-native deferred-spend design — the retry policy lives in the
  context that understands it (confirmed spends MUST eventually resolve).

  Skipped in :test (tests drive ChainStore directly and don't want a background sweeper).
  """
  use GenServer
  require Logger

  @default_interval_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    # Run the boot sweep after init returns (the store/tree is up first), then tick.
    {:ok, %{interval: interval}, {:continue, :boot_recover}}
  end

  @impl true
  def handle_continue(:boot_recover, state) do
    sweep("boot recovery")
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    sweep("periodic reconcile")
    schedule(state.interval)
    {:noreply, state}
  end

  defp sweep(label) do
    case Cardamom.ChainStore.reconcile_unprocessed_blocks() do
      0 -> :ok
      n -> Logger.info("reconciler (#{label}): re-processed #{n} un-extracted block(s)")
    end
  rescue
    # Never let a reconcile error take the process down — it'll try again next tick.
    e -> Logger.warning("reconciler (#{label}) error: #{inspect(e)} (will retry)")
  end

  defp schedule(interval), do: Process.send_after(self(), :reconcile, interval)
end
