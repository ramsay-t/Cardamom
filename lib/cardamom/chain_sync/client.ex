defmodule Cardamom.ChainSync.Client do
  @moduledoc """
  Drives the chain-sync mini-protocol (2) as the CLIENT/initiator: we hold agency
  at StIdle, so we send `MsgRequestNext`, receive `RollForward`/`RollBackward`/
  `AwaitReply`, emit telemetry, feed the forest, and ask again. Pull-based — the
  relay paces us, we never flood it.

  This is a process holding the BEARER (`Cardamom.Connection`) pid, like every
  other mini-protocol. It registers for proto 2, receives inbound SDUs as
  `{:sdu, 2, payload}`, and writes via `Connection.send_frame/3` (the bearer is the
  sole socket owner). On RollForward it strips the transport envelope
  (wrapCBORinCBOR + era tag) to raw header bytes and hands them to the LEDGER layer
  (the network layer is generic over header *meaning*).

  Milestone-1 scope: observe + log + feed the forest. Trust everything; nothing
  validated yet.

  Opts:
    * `:conn`   — the bearer pid (required)
    * `:peer`   — label for telemetry/logs
    * `:ledger` — `{module, state}`; defaults to the trust-everything Stub
  """

  use GenServer
  require Logger

  alias Cardamom.Protocol.ChainSync.Codec, as: ChainSync
  alias Cardamom.Mux.Reassembler

  @chain_sync 2
  # Default era for header shapes that arrive WITHOUT an era tag (older bare-bytes fixtures).
  # 4 = Alonzo/TPraos — the 15-field shape HeaderBuilder produces. Real relays always send the
  # tag, and HeaderBuilder now tags its envelope era 4 too; this is just the no-tag fallback.
  @default_era 4

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    peer = Keyword.get(opts, :peer, "loopback")
    ledger = Keyword.get(opts, :ledger, {Cardamom.Ledger.Stub, nil})
    # Resume from the stored tip by default; tests of pure message-handling pass
    # resume: false to force the cold-start (genesis) path regardless of store state.
    resume? = Keyword.get(opts, :resume, true)
    # PIPELINE DEPTH: how many MsgRequestNext we keep in flight. Chain-sync is a single ordered
    # channel (replies come back IN chain order, not raced), so pipelining hides the per-header
    # round-trip latency WITHOUT changing delivery order — headers still arrive parent→child.
    # depth 1 = the old strict request→reply→request (RTT-bound, ~4/s on Preview). Higher fills
    # the RTT gap. Param so it's tunable; default 10.
    depth = Keyword.get(opts, :pipeline_depth, Application.get_env(:cardamom, :chainsync_depth, 10))

    # Reflect the bearer's fate; trap exits so terminate/2 can send a polite MsgDone.
    Process.link(conn)
    Process.flag(:trap_exit, true)

    :ok = Cardamom.Connection.register(conn, @chain_sync)

    # `reasm` carries the partial tail of a message split across SDU boundaries (a ~1KB
    # header), via the generic Cardamom.Mux.Reassembler. Empty between whole messages.
    # `awaiting_intersect?`: after a FindIntersect, the producer's FIRST RollBackward is the
    # protocol CURSOR-SET to the intersection point — NOT a chain reorg. We must NOT apply a UTxO
    # rollback for it (that would delete everything above the intersection — the 136k-block wipe
    # bug: on resume the intersection is far behind our accumulated txos, so a blind rollback
    # nukes them). We set this true when we resume-via-FindIntersect, and clear it on the first
    # RollBackward (treated as the cursor-set). Only RollBackwards received while actively
    # streaming (awaiting_intersect? false) are real reorgs that rewind confirmed state.
    state = %{
      conn: conn,
      peer: peer,
      headers_seen: 0,
      ledger: ledger,
      reasm: Reassembler.new(),
      awaiting_intersect?: false,
      # Pipelining: `depth` is the target in-flight RequestNext count; `in_flight` the current.
      # We only pipeline while STREAMING (after the cursor-set); the resume/intersect phase stays
      # single-in-flight (request one, wait) so we don't fire requests before the cursor exists.
      depth: depth,
      in_flight: 0
    }

    # RESUME (reverse direction): before demanding from genesis, ask ChainStore where we left
    # off. If we have durable headers, FindIntersect from the highest — the peer rolls us back to
    # the most recent SHARED point and forward through the real chain. Cold start → origin.
    state =
      case resume? && resume_point() do
        [_slot, _hash] = point ->
          Logger.info("chain_sync peer=#{peer}: resuming from stored tip — FindIntersect")
          find_intersect(state, [point])
          # FindIntersect isn't a RequestNext; in_flight stays 0. The cursor-set RollBackward
          # arrives, then we start pipelining. awaiting_intersect? guards until then.
          %{state | awaiting_intersect?: true}

        _ ->
          # Cold start from origin: send ONE request; its first reply is the cursor-set
          # RollBackward. Pipelining begins after that.
          request_next(state)
          %{state | awaiting_intersect?: true, in_flight: 1}
      end

    {:ok, state}
  end

  @impl true
  def handle_info({:sdu, @chain_sync, payload}, state) do
    # RAW chain-sync payload bytes, exactly as they came off the wire, BEFORE any decode. Tagged
    # category: :raw_bytes — DROPPED by the file handler's filter unless raw-byte logging is on
    # (Cardamom.Debug; off by default since headers.raw keeps these bytes and the flood is huge).
    Logger.debug(
      fn -> "chain_sync raw payload: " <> Base.encode16(payload, case: :lower) end,
      Cardamom.Debug.tag()
    )

    # Reassemble via the generic Reassembler: carries a message split across SDUs (a
    # ~1KB header) AND drains many-messages-per-SDU (a relay may pack >1 message in one
    # SDU — decoding only the first is the CDDL-framing bug). Fold each whole message
    # through handle_msg.
    {:noreply, reassemble(payload, state)}
  end

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  defp reassemble(payload, %{reasm: reasm} = state) do
    case Reassembler.feed(reasm, payload, &ChainSync.decode/1) do
      {msgs, reasm} ->
        Enum.reduce(msgs, %{state | reasm: reasm}, &handle_msg/2)

      {:error, msgs, {:error, reason}} ->
        Logger.warning("chain_sync decode error: #{inspect(reason)}")
        Enum.reduce(msgs, %{state | reasm: Reassembler.new()}, &handle_msg/2)
    end
  end

  defp handle_msg({:roll_forward, header, tip}, state) do
    # Hand the header to the LEDGER layer (the network layer is generic over what a
    # header means). The full raw header hex is logged at lazy :debug inside
    # header_meta/1 — that IS our capture mechanism (no separate capture flag).
    meta = header_meta(header) |> Map.put(:tip, describe(tip))

    # A (re)seen header INVALIDATES any "done" state for its block: if we already have the block
    # stored, reset txo_processed=false so the reconciler RE-EXTRACTS it. This makes the header
    # the source of truth and the block's TXO extraction a derived, self-healing consequence —
    # so a block whose txos were wiped (e.g. by a bad rollback) rebuilds the next time its header
    # streams past, with no stale-flag bookkeeping to trust. Re-extraction is idempotent (UPSERT),
    # so re-seeing a header whose txos are fine is a harmless no-op.
    mark_block_for_reextract(meta[:header_hash])

    emit("RollForward", meta, state)
    # A header is a reply to one in-flight RequestNext: consume it, clear awaiting_intersect? (the
    # first reply — fwd OR back — means the cursor is set and we're streaming), then refill the
    # pipeline to `depth` so we always have up to N requests outstanding, hiding the round-trip.
    # (A RollForward as the FIRST reply happens when there's nothing to roll back to — the
    # intersection is at/ahead of our tip; the producer just streams forward.)
    state = %{reply_received(state) | awaiting_intersect?: false} |> fill_pipeline()
    %{state | headers_seen: state.headers_seen + 1}
  end

  # The CURSOR-SET RollBackward that FOLLOWS a FindIntersect: the producer is establishing our
  # read cursor at the intersection point, NOT reorging. We have not rolled forward past it, so
  # there is nothing to undo — applying a UTxO rollback here would delete all state above the
  # intersection (the 136k-block wipe). Skip the rollback; NOW start pipelining the stream.
  defp handle_msg({:roll_backward, point, tip}, %{awaiting_intersect?: true} = state) do
    emit("RollBackward", %{point: describe(point), tip: describe(tip), cursor_set: true}, state)
    # The cursor is established; begin streaming with the full pipeline. (This RollBackward was
    # the reply to our single resume/cold-start request, so consume it first.)
    state = %{reply_received(state) | awaiting_intersect?: false}
    fill_pipeline(state)
  end

  defp handle_msg({:roll_backward, point, tip}, state) do
    emit("RollBackward", %{point: describe(point), tip: describe(tip)}, state)
    # A genuine REORG while streaming: rewind the forest tip AND the confirmed UTxO set (resurrect
    # spends + delete outputs above the point, graveyard orphaned blocks) so we don't diverge from
    # consensus. Only reached when NOT awaiting the post-intersect cursor-set. Best-effort.
    apply_rollback(point)
    state |> reply_received() |> fill_pipeline()
  end

  # Reply to our FindIntersect. Per the ChainSync protocol, IntersectFound returns agency to the
  # CLIENT at StIdle: we send ONE MsgRequestNext, and THAT request's reply is the cursor-set
  # RollBackward (the producer sets our read pointer to the intersection). So we stay single-in-
  # flight (in_flight: 1) through the intersect phase; pipelining only begins after the cursor-set
  # (awaiting_intersect? still guards it). We DON'T fill_pipeline here — the cursor isn't set yet.
  defp handle_msg({:intersect_found, point, tip}, state) do
    emit("IntersectFound", %{point: describe(point), tip: describe(tip)}, state)
    request_next(state)
    %{state | in_flight: 1}
  end

  defp handle_msg({:intersect_not_found, tip}, state) do
    # No shared point — sync from where the peer starts us. Same as IntersectFound: send one
    # request; its reply is the cursor-set RollBackward, after which pipelining begins.
    emit("IntersectNotFound", %{tip: describe(tip)}, state)
    request_next(state)
    %{state | in_flight: 1}
  end

  defp handle_msg(:await_reply, state) do
    emit("AwaitReply", %{}, state)
    # We're at the TIP — a pipelined request had no header to serve yet. Consume the reply but do
    # NOT refill (that would spam requests into the tip). The next RollForward/Backward the server
    # sends when a block is minted refills the pipeline. So near the tip the pipeline drains to 0
    # and we sit waiting, which is correct.
    reply_received(state)
  end

  defp handle_msg(other, state) do
    emit("ChainSync", %{msg: inspect(other)}, state)
    state
  end

  # Reset the stored block's txo_processed flag (if we have the block) so it gets re-extracted.
  # hash is hex from header_meta; the store keys blocks by binary hash. Best-effort.
  defp mark_block_for_reextract(hex) when is_binary(hex) do
    with {:ok, bin} <- Base.decode16(hex, case: :lower),
         true <- Process.whereis(Cardamom.ChainStore) != nil do
      Cardamom.ChainStore.mark_block_unprocessed(bin)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp mark_block_for_reextract(_), do: :ok

  # Roll back the forest tip and the confirmed UTxO set to `point`'s slot. `point` is `[slot, hash]`
  # (or origin = genesis). Resilient: each side guarded by whether its process is up.
  defp apply_rollback(point) do
    slot = rollback_slot(point)

    if Process.whereis(Cardamom.Forest.Server), do: Cardamom.Forest.Server.rollback(point)
    if slot && Process.whereis(Cardamom.ChainStore), do: Cardamom.ChainStore.rollback(slot)
    :ok
  rescue
    e -> Logger.warning("rollback failed: #{inspect(e)}")
  end

  # Slot to roll the UTxO set back to. `[slot, _hash]` → slot; origin/genesis → 0 (roll back all).
  defp rollback_slot([slot | _]) when is_integer(slot), do: slot
  defp rollback_slot(_), do: 0

  # Send ONE MsgRequestNext (used by init's single resume/cold-start request). Returns :ok; the
  # caller sets in_flight explicitly. Streaming handlers use fill_pipeline/1 instead.
  defp request_next(state),
    do: Cardamom.Connection.send_frame(state.conn, @chain_sync, ChainSync.encode(:request_next))

  # A reply (RollForward/RollBackward/AwaitReply) consumed one outstanding request.
  defp reply_received(%{in_flight: n} = state), do: %{state | in_flight: max(n - 1, 0)}

  # Top the pipeline back up to `depth` outstanding RequestNexts. Sends (depth - in_flight)
  # requests back-to-back — the relay streams the replies in chain order, hiding the round-trip.
  # No-op once we're at depth. Not used while awaiting the intersect cursor-set (single-in-flight).
  defp fill_pipeline(%{depth: depth, in_flight: in_flight} = state) when in_flight < depth do
    to_send = depth - in_flight
    Enum.each(1..to_send, fn _ -> request_next(state) end)
    %{state | in_flight: in_flight + to_send}
  end

  defp fill_pipeline(state), do: state

  defp find_intersect(state, points),
    do: Cardamom.Connection.send_frame(state.conn, @chain_sync, ChainSync.encode({:find_intersect, points}))

  # The resume point from the durable store (the forest's judged tip + its slot), or
  # nil for a cold start. Best-effort: absent in bare unit tests (no store running).
  defp resume_point do
    if Process.whereis(Cardamom.Store.Repo), do: Cardamom.ChainStore.resume_point(), else: nil
  rescue
    _ -> nil
  end

  defp emit(msg, extra, state) do
    meta = Map.merge(%{protocol: "chain_sync", msg: msg, peer: state.peer}, extra)
    :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, meta)
    Logger.info("chain_sync #{msg} #{inspect(extra)}")
  end

  # Turn a RollForward header term into log/telemetry metadata via the LEDGER layer.
  # The header arrives wrapped (wrapCBORinCBOR + an ERA TAG); we strip the transport envelope
  # to {era_tag, raw header bytes} (a NETWORK concern), then the era-dispatching ledger decoder
  # interprets them (its concern) — Byron / TPraos / Praos all have different header shapes, so
  # the era tag is what selects the right decoder. EVERY successfully-decoded era is fed to the
  # forest and persisted: that is what lets the chain advance across hard forks (the old code
  # only knew one shape and silently dropped all others). NEVER reconstruct bytes by re-encoding.
  defp header_meta(header) do
    case unwrap_header(header) do
      {era, raw} when is_binary(raw) ->
        decode_and_store(era, raw)

      _ ->
        Logger.warning("chain_sync: header did not match the [era, #6.24(bytes)] envelope")
        %{header_raw_term: inspect(header)}
    end
  end

  defp decode_and_store(era, raw) do
    case Cardamom.Ledger.Header.decode(era, raw) do
      {:ok, h} ->
        feed_forest(h.hash_hex, prev_hex(h.prev_hash))
        persist_header(h, raw)

        %{
          header_era: era,
          header_hash: h.hash_hex,
          header_slot: h.slot,
          header_block: h.block_number,
          header_prev: prev_hex(h.prev_hash),
          header_bytes: byte_size(raw)
        }

      {:error, reason} ->
        # A genuine decode failure — log it LOUDLY with the era so shape drift (e.g. a new hard
        # fork we don't yet decode) is visible, not silently swallowed like the pre-fix bug.
        Logger.warning("chain_sync: header decode FAILED era=#{era} reason=#{inspect(reason)}")
        %{header_era: era, header_decode_error: inspect(reason), header_bytes: byte_size(raw)}
    end
  end

  defp prev_hex(nil), do: nil
  defp prev_hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  # Feed the forest if one is running (best-effort; absent in unit tests).
  defp feed_forest(hash_hex, parent_hex) do
    if Process.whereis(Cardamom.Forest.Server) do
      Cardamom.Forest.Server.add_header(hash_hex, parent_hex)
    end

    :ok
  end

  # Persist the decoded header (+ verbatim raw bytes) to the durable store, if it's
  # running (best-effort; absent in bare unit tests). This is the forward/write half:
  # everything chain-sync sees lands in SQLite so a restart can resume from it.
  # Store EVERYTHING that arrives, verdict-free — orphans, fork losers, and (once we
  # validate) invalid headers all get a durable row. The header table is forensic
  # truth, NOT a set of trusted headers. So we do NOT write a "tip" here: the latest
  # RollForward is just "the last thing this relay sent", not our believed tip. The
  # tip / resume points are the FOREST's judgement (its connected — later, valid —
  # leaves), recorded at shutdown / on demand, not from this linear stream.
  defp persist_header(h, raw) do
    if Process.whereis(Cardamom.Store.Repo) do
      Cardamom.ChainStore.put_decoded_header(h, raw)
    end

    :ok
  rescue
    e -> Logger.warning("chain_store put_header failed: #{inspect(e)}")
  end

  # Strip the transport envelope to `{era_tag, raw header bytes}`. CONFIRMED from real Preview:
  # `[era, #6.24(bytes)]` — era tag, then CBOR tag-24 (wrapCBORinCBOR) wrapping the header byte
  # string. We KEEP the era tag now (the era-dispatching decoder needs it; Byron/TPraos/Praos
  # are different shapes). The no-era / bare-bytes shapes are SimPeer/older fixtures; default
  # them to era 6 (Conway/Praos), which is what the builder now emits. Anything unrecognised →
  # nil (caller logs the raw term rather than inventing data).
  defp unwrap_header([era, %CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: raw}}])
       when is_integer(era) and is_binary(raw),
       do: {era, raw}

  defp unwrap_header(%CBOR.Tag{tag: 24, value: %CBOR.Tag{tag: :bytes, value: raw}})
       when is_binary(raw),
       do: {@default_era, raw}

  defp unwrap_header([era, %CBOR.Tag{tag: :bytes, value: raw}]) when is_integer(era) and is_binary(raw),
    do: {era, raw}

  defp unwrap_header(%CBOR.Tag{tag: :bytes, value: raw}) when is_binary(raw), do: {@default_era, raw}
  defp unwrap_header(raw) when is_binary(raw), do: {@default_era, raw}
  defp unwrap_header(_other), do: nil


  defp describe([slot | _]) when is_integer(slot), do: %{slot: slot}
  defp describe(other), do: %{raw: inspect(other)}

  # Polite goodbye: on a clean shutdown send chain-sync MsgDone (reaches StDone) so
  # the peer sees an intentional disconnect. We're ordered before the bearer in the
  # session supervisor, so this reaches the wire before the socket closes. Abnormal
  # death just drops (the relay sees a normal dropped connection).
  @impl true
  def terminate(reason, state) do
    if clean?(reason) and Process.alive?(state.conn) do
      # SYNCHRONOUS: guarantees MsgDone reaches the socket before we exit (and before
      # the link-death signal closes the bearer). A cast would race that and lose.
      Logger.info("chain_sync peer=#{state.peer}: sending MsgDone (clean close)")
      _ = Cardamom.Connection.send_frame_sync(state.conn, @chain_sync, ChainSync.encode(:done))
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
end
