defmodule Cardamom.LogDurabilityTest do
  use ExUnit.Case, async: false

  # Two shutdown/logging guarantees pinned here:
  #
  # 1) The truncated-log bug: on a BUSY node (header flood) the graceful-shutdown teardown lines
  #    (Session.terminate → "sending MsgDone") never reached the file — the log cut off mid-sync.
  #    Cause: :logger_std_h's BURST LIMITER (burst_limit_max_count 500 / window 1000ms) plus the
  #    drop/flush qlens DISCARD messages under load. file_handler_config/1 disables all of that.
  #
  # 2) The :raw_bytes category: raw wire-byte dumps are tagged category: :raw_bytes and DROPPED by
  #    a handler filter unless raw-byte logging is enabled (Cardamom.Debug). Off by default.

  @handler :cardamom_logdur_test

  setup do
    path = Path.join(System.tmp_dir!(), "cardamom-logdur-#{System.unique_integer([:positive])}.log")
    :ok = :logger.add_handler(@handler, :logger_std_h, Cardamom.Application.file_handler_config(path))
    :logger.set_primary_config(:level, :debug)

    on_exit(fn ->
      :logger.remove_handler(@handler)
      File.rm(path)
    end)

    {:ok, path: path}
  end

  # Route an event ONLY to our test handler's file: log at :debug; the default handler may also
  # see it but we only read our file. Use the 2-arity form (msg only).
  defp emit(level, msg, meta \\ %{}), do: :logger.log(level, msg, meta)

  defp read_after_sync(path) do
    :ok = :logger_std_h.filesync(@handler)
    Process.sleep(150)
    File.read!(path)
  end

  test "the production file-handler config keeps the teardown line under a log flood", %{path: path} do
    # A flood far past the default burst_limit (500/window) and flush_qlen (1000), which WOULD
    # have discarded later messages with the stock config.
    for i <- 1..5_000, do: emit(:info, "flood line #{i}")
    marker = "TEARDOWN MARKER shutdown peer=testpeer sending MsgDone clean close"
    emit(:info, marker)

    contents = read_after_sync(path)

    assert contents =~ marker,
           "teardown marker was DROPPED under load — overload/burst protection discarded it (the truncated-log bug)"

    assert contents =~ "flood line 5000",
           "flood was truncated — burst_limit / drop_mode_qlen still shedding messages"
  end

  test "config matches what the app attaches (no drift)" do
    cfg = Cardamom.Application.file_handler_config("/tmp/whatever.log")
    assert cfg.config.burst_limit_enable == false
    assert cfg.config.sync_mode_qlen == 0
    assert cfg.config.drop_mode_qlen >= 1_000_000_000
    assert cfg.config.flush_qlen >= 1_000_000_000
    assert cfg.config.filesync_repeat_interval == 100
  end

  test ":raw_bytes-tagged events are DROPPED when disabled, PASS when enabled", %{path: path} do
    Cardamom.Debug.disable_raw_bytes(@handler)
    emit(:debug, "RAWBYTES_WHEN_DISABLED", Map.new(Cardamom.Debug.tag()))
    emit(:info, "ORDINARY_WHEN_DISABLED")
    disabled = read_after_sync(path)

    refute disabled =~ "RAWBYTES_WHEN_DISABLED",
           "raw_bytes category should be filtered out when disabled"
    assert disabled =~ "ORDINARY_WHEN_DISABLED", "ordinary logs must still pass"

    Cardamom.Debug.enable_raw_bytes(@handler)
    emit(:debug, "RAWBYTES_WHEN_ENABLED", Map.new(Cardamom.Debug.tag()))
    enabled = read_after_sync(path)

    assert enabled =~ "RAWBYTES_WHEN_ENABLED",
           "raw_bytes category should reach the file once enabled"

    # leave it disabled for other tests
    Cardamom.Debug.disable_raw_bytes(@handler)
  end
end
