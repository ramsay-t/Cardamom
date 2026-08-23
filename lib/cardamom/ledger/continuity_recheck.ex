defmodule Cardamom.Ledger.ContinuityRecheck do
  @moduledoc """
  Re-runs Tier-1 header CONTINUITY when a previously-floating header becomes CONNECTED in the
  forest. Closes the deferral in `Cardamom.Ledger.HeaderHandler`: a header that arrived before its
  parent skips continuity at the gate (out-of-order backfill is normal); when the forest links it
  to its parent it emits `[:cardamom, :forest, :connected]`, and this subscriber runs the check
  now that the parent is guaranteed present.

  Subscribes to the telemetry event (the forest stays dumb — it announces connection, it does not
  validate); on the event it looks the header + parent up in the store and runs
  `Cardamom.Ledger.Praos.Continuity`. A PASS is silent. A genuine `{:invalid, _}` is a real
  finding — the header linked to a parent it doesn't legitimately follow (wrong number / slot).

  ACTION ON INVALID (deliberate, minimal for now): log + emit `[:cardamom, :ledger, :divergence]`
  — the same signal the ledger conformance oracles use for "we found wrongness". We do NOT yet
  drop/graveyard the header: header removal + a fork-closure forensic record is a separate design
  (the write-only forensic store), and on a follower an invalid backfilled header is inert until
  something selects onto it. FLAGGED for the relay milestone: before SERVING, an invalid-on-connect
  header must not be servable — wire the drop/graveyard there.
  """
  use GenServer
  require Logger

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Praos.Continuity

  @event [:cardamom, :forest, :connected]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    id = {__MODULE__, self()}
    :telemetry.attach(id, @event, &__MODULE__.handle_event/4, self())
    {:ok, %{id: id}}
  end

  @impl true
  def terminate(_reason, %{id: id}), do: :telemetry.detach(id)

  # Telemetry callback (runs in the emitting process) — just forward to our own process, so the
  # store lookups + check happen off the forest's call path.
  def handle_event(@event, _meas, %{hash: hash}, pid), do: send(pid, {:connected, hash})
  def handle_event(_e, _m, _meta, _pid), do: :ok

  @impl true
  def handle_info({:connected, hash_hex}, state) when is_binary(hash_hex) do
    recheck(hash_hex)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Re-run continuity for a now-connected header (public for direct testing)."
  def recheck(hash_hex) do
    with h when not is_nil(h) <- lookup(hash_hex),
         parent <- lookup_parent(h) do
      case Continuity.check(h, parent) do
        :ok -> :ok
        {:skip, _} -> :ok
        {:invalid, reason} -> diverge(hash_hex, reason)
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # The forest keys by hex hash; the store keys by raw bytes. Load the stored header row and shape
  # it into the field names Continuity expects (block_number/slot/prev_hash).
  defp lookup(hash_hex) do
    with {:ok, raw_hash} <- Base.decode16(hash_hex, case: :lower),
         %{block_no: n, slot: slot, prev_hash: prev} <- ChainStore.get_header(raw_hash) do
      %{block_number: n, slot: slot, prev_hash: prev}
    else
      _ -> nil
    end
  end

  defp lookup_parent(%{prev_hash: nil}), do: :not_found

  defp lookup_parent(%{prev_hash: prev}) do
    case ChainStore.get_header(prev) do
      %{block_no: n, slot: slot} -> %{block_no: n, slot: slot}
      _ -> :not_found
    end
  end

  defp diverge(hash_hex, reason) do
    Logger.warning("continuity DIVERGENCE on connect: header=#{hash_hex} #{inspect(reason)}")
    :telemetry.execute([:cardamom, :ledger, :divergence], %{diff: 1}, %{
      check: :header_continuity,
      header: hash_hex,
      reason: inspect(reason)
    })
  end
end
