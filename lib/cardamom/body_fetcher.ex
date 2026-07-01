defmodule Cardamom.BodyFetcher do
  @moduledoc """
  The metronome that keeps block BODIES caught up with HEADERS. Every `interval_ms` it asks the
  store for the next run of headers we don't have bodies for (up to `batch`, default 500) and
  fetches them via `ChainStore.get_blocks/1` — which range-requests consecutive misses as ONE
  block-fetch range (never N×1). Each fetched body is verified + stored + TXO-extracted by the
  existing ingest path.

  This is the GOING-FORWARD trigger AND the genesis backfill, in one loop: it simply drains
  "headers ahead of bodies" a window at a time until caught up, then idles (empty runs are a
  no-op) until chain-sync brings new headers. It REVERSES the earlier "bodies purely on-demand"
  stance — bodies are now proactively synced so the full UTxO set can be built (goal b:
  resolve any contract's current datum). See project_utxo_block_traceability.

  Config-toggleable via `:fetch_bodies` (default on outside :test); skipped in :test (tests
  drive block fetch explicitly). Out-of-order spends across range boundaries are handled by the
  ChainStore deferred-spend retriers + reconciler, so a window can be fetched without worrying
  about producer-before-spender ordering.
  """
  use GenServer
  require Logger

  @default_interval_ms 5_000
  # Blocks per range-fetch tick. 1000 = bigger chunks, fewer ticks; the relay serves partial
  # batches and byte-caps a RequestRange anyway, so this is an upper bound per tick, not a
  # guarantee. Tunable via the `body_batch` param (get_blocks range-fetches the consecutive run).
  @default_batch 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval_ms, @default_interval_ms),
      batch: Keyword.get(opts, :batch, Application.get_env(:cardamom, :body_batch, @default_batch))
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state) do
    fetch_next(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    fetch_next(state)
    schedule(state.interval)
    {:noreply, state}
  end

  # One window: grab the next run of header points without bodies, range-fetch them. Empty run
  # → caught up, nothing to do this tick.
  defp fetch_next(state) do
    case Cardamom.ChainStore.headers_missing_bodies(state.batch) do
      [] ->
        :ok

      points ->
        Logger.info("body_fetcher: fetching #{length(points)} block bodies (slots #{slot_span(points)})")
        Cardamom.ChainStore.get_blocks(points)
    end
  rescue
    # A fetch error (no peer, timeout) must not kill the metronome — it retries next tick.
    e -> Logger.warning("body_fetcher tick error: #{inspect(e)} (will retry)")
  end

  defp slot_span(points) do
    slots = Enum.map(points, fn [s, _h] -> s end)
    "#{Enum.min(slots)}..#{Enum.max(slots)}"
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
