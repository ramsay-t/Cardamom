defmodule Cardamom.Debug do
  @moduledoc """
  The `:raw_bytes` log category.

  Erlang's :logger has a FIXED set of 8 levels (emergency…debug) — you cannot add a 9th like
  `:raw_bytes` (it's a badarg, same as an unknown OS signal). The idiomatic way to get a
  separate, independently-toggleable category *below* debug is therefore a metadata TAG plus a
  handler FILTER, not a new level. Raw wire-byte dumps (the full hex of every chain-sync
  header, peer-sharing reply, tx) are logged at `:debug` but tagged `category: :raw_bytes`;
  the file handler carries a filter that DROPS that category unless it's been switched on.

  Why off by default: those dumps were our byte-level proof during reassembly/decoding
  bring-up, but the raw bytes are now kept durably in the store (headers.raw, blocks.raw, …)
  and the flood is ENORMOUS (~38MB / 2 min). The DB is the source of truth; the log category
  is for live byte-level diagnosis / Cardamom.LogReplayPeer only.

  Toggle at RUNTIME (no restart) — the whole point of doing this as a filter:

      Cardamom.Debug.enable_raw_bytes()
      Cardamom.Debug.disable_raw_bytes()

  Or at boot via the params file key `"debug_raw_bytes": true` (→ app env :debug_raw_bytes),
  or env var CARDAMOM_DEBUG_RAW_BYTES=1.
  """
  require Logger

  @category :raw_bytes
  @filter_id :cardamom_raw_bytes
  @default_handler :cardamom_file

  @doc "The metadata to tag a raw-byte log call with: `Logger.debug(fn -> … end, Cardamom.Debug.tag())`."
  def tag, do: [category: @category]

  @doc "The category atom, for filters/tests."
  def category, do: @category

  @doc "Whether raw-byte logging is enabled at boot (env var or app env). Default false."
  @spec enabled_at_boot?() :: boolean()
  def enabled_at_boot? do
    System.get_env("CARDAMOM_DEBUG_RAW_BYTES") in ["1", "true"] or
      Application.get_env(:cardamom, :debug_raw_bytes, false) == true
  end

  @doc """
  A :logger primary/handler filter: STOPS (drops) events tagged `category: :raw_bytes` so they
  never reach the file, while letting everything else through unchanged. Installed on the file
  handler; removed to let raw bytes through. `_extra` is the filter's config arg (unused).
  """
  def drop_raw_bytes(%{meta: %{category: @category}} = _event, _extra), do: :stop
  def drop_raw_bytes(event, _extra), do: event

  @doc """
  Install the drop-filter on the file handler (raw bytes OFF). Idempotent / best-effort.
  `handler` defaults to the app's file handler; tests pass their own handler name.
  """
  def disable_raw_bytes(handler \\ @default_handler) do
    # Remove first so we don't error on a duplicate id, then add.
    _ = :logger.remove_handler_filter(handler, @filter_id)
    :logger.add_handler_filter(handler, @filter_id, {&__MODULE__.drop_raw_bytes/2, []})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Remove the drop-filter (raw bytes ON — they now reach the file). Best-effort."
  def enable_raw_bytes(handler \\ @default_handler) do
    :logger.remove_handler_filter(handler, @filter_id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Apply the boot default: drop raw bytes unless enabled_at_boot?/0. Called from Application.start."
  def apply_boot_default do
    if enabled_at_boot?(), do: enable_raw_bytes(), else: disable_raw_bytes()
  end
end
