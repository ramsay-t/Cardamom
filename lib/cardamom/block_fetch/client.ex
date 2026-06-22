defmodule Cardamom.BlockFetch.Client do
  @moduledoc """
  Drives the block-fetch mini-protocol (3) as the CLIENT. Like every mini-protocol
  it's a process holding the bearer (`Cardamom.Connection`) pid; it registers for
  proto 3 and writes via the bearer (single writer).

  Protocol (ouroboros-network):
      we send:  MsgRequestRange [0, from_point, to_point]
      relay:    MsgStartBatch [2]  ->  MsgBlock [4, #6.24(block)] x N  ->  MsgBatchDone [5]
                or MsgNoBlocks [3]

  STREAMING design (NOT accumulate-then-reply — see project_cardamom_blockfetch_design):
  each block, the INSTANT its bytes arrive, is handed to a SINK fn that runs in its OWN
  spawned process (decode + verify + store). Nothing is accumulated here; a block that
  arrives is processed immediately, so partial progress can't be lost on disconnect.

  `fetch_range/4` is synchronous and returns a COMPLETION SIGNAL — NOT the blocks:
    * `:ok`    — the relay sent BatchDone/NoBlocks AND every spawned block handler has
                 FINISHED (decoded + stored). The caller may now read the store.
    * `:error` — 30s of IDLE (no block-fetch bytes; reset per SDU — the relay stalled),
                 or the channel died.

  The reply waits for handlers to finish (not merely spawn) — else the caller reads
  the store before a still-decoding block has landed (a race). We track outstanding
  handlers and reply at the join: batch terminated AND in_flight == 0.
  """

  use GenServer
  require Logger

  alias Cardamom.Protocol.BlockFetch.Codec

  @block_fetch 3
  # Idle timeout: max silence (no block-fetch bytes) before we give up on the peer.
  # 90s — comfortably above the protocol's own per-message patience (longWait = 60s,
  # ouroboros-network Protocol/Limits.hs, the timeout for BFBusy/BFStreaming). We were
  # at 30s, which is MORE impatient than the spec; a relay that pauses mid-range
  # legitimately may take up to 60s before its next message.
  @idle_timeout_ms 90_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc """
  Fetch the inclusive range `from_point`..`to_point` (each `[slot, hash]`). Each block
  is passed to `sink` (a `fn raw_block_bytes -> any end`) in its OWN process as it
  arrives. Returns `:ok` (batch done + all handlers finished) or `{:error, reason}`
  (idle timeout / dead channel). Does NOT return the blocks — the sink stored them;
  the caller reads the store.

  `call_timeout` bounds the whole synchronous call; pass :infinity to rely solely on
  the internal idle timeout (recommended — a big honest range may stream for minutes).
  """
  def fetch_range(client, from_point, to_point, sink, call_timeout \\ :infinity) do
    GenServer.call(client, {:fetch_range, from_point, to_point, sink}, call_timeout)
  end

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    Process.link(conn)
    Process.flag(:trap_exit, true)
    :ok = Cardamom.Connection.register(conn, @block_fetch)
    # `buffer` carries the partial tail of a mini-protocol message that was split
    # across SDU boundaries — prepended to the next SDU's bytes. Empty whenever the
    # protocol is between whole messages (idle); non-empty means a message is in
    # flight across SDUs. (The 1962 mux invariant: reassemble across time slots.)
    {:ok, %{conn: conn, peer: Keyword.get(opts, :peer, "loopback"), req: nil, buffer: <<>>}}
  end

  @impl true
  def handle_call({:fetch_range, from, to, sink}, from_caller, %{req: nil} = state) do
    Cardamom.Connection.send_frame(state.conn, @block_fetch, Codec.encode({:request_range, from, to}))

    # req tracks the in-flight request: who's waiting, the per-block sink, how many
    # block handlers are still running, and whether the batch has terminated.
    # terminating: nil while the batch is still streaming; set to :ok (BatchDone /
    # NoBlocks) or {:error, _} (idle stall) once the relay is done. The reply fires —
    # with that outcome — only when terminating != nil AND in_flight == 0.
    req = %{reply_to: from_caller, sink: sink, in_flight: 0, terminating: nil}
    {:noreply, %{state | req: req} |> arm_idle()}
  end

  def handle_call({:fetch_range, _, _, _}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_info({:sdu, @block_fetch, payload}, state) do
    # NOTE: we deliberately do NOT log the raw block payload here. A block is multi-KB,
    # which exceeds Logger's default 8192-byte truncation → the line would be an
    # INCOMPLETE, useless half-capture (and a disk flood at multi-peer/forwarding
    # scale). The COMPLETE raw bytes are preserved verbatim in the durable store
    # (blocks.raw, hash-verified) — that IS the forensic record. (Contrast chain-sync
    # headers, which fit under 8192 and are logged whole.)
    # Prepend any carried-over partial tail, then drain ALL whole messages. A relay
    # packs e.g. last Block + BatchDone in one SDU (drain loops), AND a single block
    # can be split across SDUs (the leftover tail is held in `buffer` for next time).
    # Reset the idle timer — we got bytes, the peer is alive.
    state = arm_idle(state)
    {state, rest} = drain(state.buffer <> payload, state)
    {:noreply, %{state | buffer: rest}}
  end

  # A spawned block handler finished (decoded + stored). Decrement in-flight; if the
  # request is terminating (batch done OR idle-stalled) and this was the last handler,
  # reply now.
  def handle_info({:handler_done, _ref}, %{req: %{} = req} = state) do
    req = %{req | in_flight: req.in_flight - 1}
    {:noreply, maybe_complete(%{state | req: req})}
  end

  def handle_info({:handler_done, _ref}, state), do: {:noreply, state}

  # Idle timeout: no block-fetch bytes for @idle_timeout_ms — the relay stalled
  # mid-batch. Mark the request as terminating with an :error outcome, but DO NOT
  # reply yet if block handlers are still running — we must wait for the blocks that
  # DID arrive to finish decoding + storing (else the caller reads the store too early
  # and reports them unavailable). maybe_complete replies once in_flight == 0.
  def handle_info({:idle_timeout, token}, %{req: %{idle_token: token} = req} = state) do
    Logger.warning("block_fetch: idle #{@idle_timeout_ms}ms — relay stalled; draining #{req.in_flight} handler(s)")
    {:noreply, maybe_complete(%{state | req: %{req | terminating: {:error, :idle_timeout}}})}
  end

  def handle_info({:idle_timeout, _stale}, state), do: {:noreply, state}

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  # Polite goodbye: on a clean shutdown send MsgClientDone ([1]) so the relay's proto-3
  # state machine reaches StDone, mirroring chain-sync's MsgDone. Block-fetch holds
  # agency at StIdle (between/after batches), so MsgClientDone is the legal close.
  # SYNCHRONOUS send — it must reach the socket before the bearer (ordered after us in
  # the session) releases it; a cast would race the link-death close and lose. Abnormal
  # death just drops (the relay sees a normal dropped connection). (Marcin 2026-06-22:
  # a dangling proto / RST reads as a client fault — leave cleanly so it can't.)
  @impl true
  def terminate(reason, state) do
    if clean?(reason) and Process.alive?(state.conn) do
      Logger.info("block_fetch peer=#{state.peer}: sending MsgClientDone (clean close)")
      _ = Cardamom.Connection.send_frame_sync(state.conn, @block_fetch, Codec.encode(:client_done))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp clean?(:normal), do: true
  defp clean?(:shutdown), do: true
  defp clean?({:shutdown, _}), do: true
  defp clean?(_), do: false

  # ---- message handling ----

  # Consume every WHOLE message in `bytes`; return {state, leftover}. `leftover` is the
  # tail of a message that isn't fully present yet (`:incomplete`) — held in `buffer`
  # and concatenated with the next SDU. A genuine decode error (corruption, not a short
  # read) is logged and the rest discarded (we can't realign mid-stream anyway).
  defp drain(<<>>, state), do: {state, <<>>}

  defp drain(bytes, state) do
    case Codec.decode(bytes) do
      {:ok, msg, rest} ->
        drain(rest, on_msg(msg, state))

      :incomplete ->
        # A message is split across the SDU boundary — keep the prefix for next time.
        {state, bytes}

      {:error, reason} ->
        Logger.warning("block_fetch decode error: #{inspect(reason)}")
        {state, <<>>}
    end
  end

  defp on_msg(:start_batch, state), do: state

  defp on_msg({:block, wrapped}, %{req: %{} = req} = state) do
    case unwrap(wrapped) do
      {:ok, raw} ->
        # SPAWN-time event: a block's bytes arrived, handing it to a decode handler.
        emit("BlockReceived", %{bytes: byte_size(raw)}, state)
        # Hand the block to its sink in its OWN process; it signals back when done so
        # we only complete once ALL handlers have finished (not merely spawned). The
        # sink emits its own "BlockStored" event with decoded detail.
        spawn_handler(raw, req.sink)
        %{state | req: %{req | in_flight: req.in_flight + 1}}

      :error ->
        Logger.warning("block_fetch: undecodable block envelope; skipping")
        state
    end
  end

  defp on_msg(:batch_done, %{req: %{} = req} = state) do
    emit("BatchDone", %{in_flight: req.in_flight}, state)
    maybe_complete(%{state | req: %{req | terminating: :ok}})
  end

  defp on_msg(:no_blocks, %{req: %{} = req} = state) do
    emit("NoBlocks", %{}, state)
    maybe_complete(%{state | req: %{req | terminating: :ok}})
  end

  # A server message with no in-flight request, or anything else — ignore.
  defp on_msg(_msg, state), do: state

  # Spawn a process that runs the sink over this block, then tells us it's done.
  defp spawn_handler(raw, sink) do
    me = self()
    ref = make_ref()

    spawn(fn ->
      try do
        sink.(raw)
      rescue
        e -> Logger.warning("block handler crashed: #{inspect(e)}")
      after
        send(me, {:handler_done, ref})
      end
    end)
  end

  # Reply ONCE the request is terminating (batch done OR idle-stalled) AND every block
  # handler has finished — whether the outcome is :ok or :error, we always wait for the
  # blocks that DID arrive to finish storing, so the caller never reads the store early.
  defp maybe_complete(%{req: %{terminating: outcome, in_flight: 0, reply_to: rt}} = state)
       when outcome != nil do
    GenServer.reply(rt, outcome)
    %{state | req: nil}
  end

  defp maybe_complete(state), do: state

  # (Re)arm the idle timer; a fresh token invalidates any prior pending timeout.
  defp arm_idle(%{req: nil} = state), do: state

  defp arm_idle(%{req: req} = state) do
    token = make_ref()
    Process.send_after(self(), {:idle_timeout, token}, @idle_timeout_ms)
    %{state | req: Map.put(req, :idle_token, token)}
  end

  # Strip the block-fetch wrapCBORinCBOR envelope (CBOR tag 24) to raw block bytes.
  defp unwrap(%CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: raw}}) when is_binary(raw),
    do: {:ok, raw}

  defp unwrap(%CBOR.Tag{tag: :bytes, value: raw}) when is_binary(raw), do: {:ok, raw}
  defp unwrap(raw) when is_binary(raw), do: {:ok, raw}
  defp unwrap(_), do: :error

  defp emit(msg, extra, state) do
    meta = Map.merge(%{protocol: "block_fetch", msg: msg, peer: state.peer}, extra)
    :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, meta)
    Logger.info("block_fetch #{msg} #{inspect(extra)}")
  end
end
