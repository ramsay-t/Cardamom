defmodule Cardamom.Replay do
  @moduledoc """
  From-genesis REPLAY (refold) driver — re-runs the ledger fold `foldl(apply_block, genesis, …)`
  over blocks WE ALREADY HAVE ON DISK, in slot order, through the real synchronous extraction
  path (`ChainStore.extract_block_sync` → the `Cardamom.Ledger.BlockHandler` validation gate).

  WHY: the reward engine + ledger-state accounting were built long after most of the chain was
  ingested, so the derived state was folded only over the tail from a made-up mid-chain
  accumulator. A correct refold must start from genesis. It is also the FALSIFICATION run: as it
  advances, every withdrawal the network accepted is checked against our derived reward balance
  (the withdrawal oracle), and every value flow against conservation — a divergence is a bug in
  our engine (or a spec finding). And it produces the contiguous in-order fold the leader-election
  oracle needs.

  DESIGN (agreed with Ramsay):
    * SLOT ORDER, SYNCHRONOUS, one block at a time — the epoch fold assumes in-order application
      (SNAP reads boundary-time state; feeSS reads pre-block fees). The concurrent reconciler
      would violate that, so replay drives extraction itself and expects the reconciler quiet.
    * `txo_processed` IS THE CHECKPOINT — resumable: a re-run skips already-processed blocks and
      continues where it stopped. Paged via `ChainStore.blocks_after/2` so the (millions-of-rows)
      table is never loaded whole.
    * STOP-AND-FIX: the gate returns `{:error, {:validation_rejected, summary}}` for a block that
      fails a conformance rule; replay HALTS there (does not plough on), returning the verdict.
      On real chain data a reject means our derivation is wrong — the whole point is to catch it.

  This module DOES NOT touch the DB destructively. Wiping derived state (txos + ledger_state +
  ledger_deltas, keeping headers + blocks.raw) before a genuine from-genesis run is a SEPARATE,
  deliberate, guarded step — Ramsay's call, live session stopped or on a copy
  ([[feedback_never_delete_data_dirs]]). See `wipe_derived_state/1`, which refuses unless armed.
  """

  require Logger

  @page 500

  @doc """
  Run the replay from the current checkpoint to the tip of stored blocks. Options:
    * `:page` — blocks per DB page (default #{@page}),
    * `:extract_timeout` — per-block sync timeout ms (default 30_000; a block with an unresolved
      cross-block producer would otherwise hang — in a from-genesis in-order fold producers
      always precede spenders, so a timeout is itself a signal),
    * `:progress_every` — emit `[:cardamom, :replay, :progress]` every N processed (default 1000),
    * `:collect_slots` — accumulate visited slots (tests/small runs only; unbounded).

  Returns `{:ok, summary}` where summary = `%{processed, skipped, visited_slots, halted}`;
  `halted` is `nil` on a full run or `%{slot, hash, verdict}` if a gate reject stopped it.
  """
  def run(opts \\ []) do
    state = %{
      cursor: nil,
      processed: 0,
      skipped: 0,
      slots: [],
      halted: nil,
      page: Keyword.get(opts, :page, @page),
      timeout: Keyword.get(opts, :extract_timeout, 30_000),
      progress_every: Keyword.get(opts, :progress_every, 1000),
      collect_slots: Keyword.get(opts, :collect_slots, false)
    }

    final = loop(state)

    {:ok,
     %{
       processed: final.processed,
       skipped: final.skipped,
       visited_slots: Enum.reverse(final.slots),
       halted: final.halted
     }}
  end

  defp loop(%{halted: h} = st) when not is_nil(h), do: st

  defp loop(st) do
    case Cardamom.ChainStore.blocks_after(st.cursor, st.page) do
      [] ->
        st

      blocks ->
        st = Enum.reduce_while(blocks, st, &step/2)
        # stop if a block halted us mid-page; else advance the cursor and page on
        if st.halted, do: st, else: loop(%{st | cursor: cursor_of(List.last(blocks))})
    end
  end

  # Process one block. reduce_while so a reject halts the fold immediately.
  defp step(%{hash: hash, slot: slot, raw: raw}, st) do
    cond do
      already_processed?(hash) ->
        {:cont, bump(%{st | skipped: st.skipped + 1}, slot)}

      true ->
        case Cardamom.ChainStore.extract_block_sync(hash, raw, slot, st.timeout) do
          :ok ->
            {:cont, progress(bump(%{st | processed: st.processed + 1}, slot))}

          {:error, {:validation_rejected, summary}} ->
            Logger.error("replay HALT at slot #{slot}: gate rejected — #{inspect(summary)}")
            {:halt, %{st | halted: %{slot: slot, hash: hash, verdict: summary}}}

          other ->
            # A crash or a timeout (unresolved producer in an in-order fold = a real anomaly).
            Logger.error("replay HALT at slot #{slot}: extraction #{inspect(other)}")
            {:halt, %{st | halted: %{slot: slot, hash: hash, verdict: other}}}
        end
    end
  end

  defp already_processed?(hash) do
    case Cardamom.ChainStore.stored_block(hash) do
      %{txo_processed: true} -> true
      _ -> false
    end
  end

  defp bump(st, slot), do: if(st.collect_slots, do: %{st | slots: [slot | st.slots]}, else: st)

  defp progress(st) do
    if rem(st.processed, st.progress_every) == 0 do
      :telemetry.execute([:cardamom, :replay, :progress], %{processed: st.processed},
        %{skipped: st.skipped})
    end

    st
  end

  defp cursor_of(%{slot: s, hash: h}), do: {s, h}

  @doc """
  DESTRUCTIVE. Wipe DERIVED state (txos + ledger_state + ledger_deltas) and reset every stored
  block to `txo_processed = false`, KEEPING headers and blocks.raw (immutable, content-verified;
  re-download would take weeks). Genesis reseeds the initial UTxO + pots on the next fold.

  GUARDED: refuses unless called with `armed: true` AND the live following stack is down (no
  Connector), so it can't fire against a running node ([[feedback_never_delete_data_dirs]],
  [[feedback_live_network_safety]]). Returns `{:error, reason}` when refused; `{:ok, counts}` when
  it wipes. This is a deliberate operator action — never called by `run/1`.
  """
  def wipe_derived_state(opts \\ []) do
    cond do
      Keyword.get(opts, :armed) != true ->
        {:error, :not_armed}

      Process.whereis(Cardamom.Connector) != nil ->
        {:error, :live_stack_running}

      true ->
        Cardamom.ChainStore.wipe_derived_state!()
    end
  end
end
