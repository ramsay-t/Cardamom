defmodule Cardamom.SimPeer do
  @moduledoc """
  A single-process, multi-protocol, directable simulated peer for tests. It plays
  the RESPONDER side of the mini-protocols over a `Cardamom.Channel`, and —
  crucially — it ENFORCES what the real Cardano node enforces, so "sim-green"
  means "Preview-ready". A fixture more lenient than reality gives false
  confidence.

  Determinism wins: ONE process, a protocol-number dispatch table, no internal
  sub-processes. Enforcement is PARAMETERISED so tests can deliberately trip each
  failure mode:

    * `:protocols` — which responders it speaks: `:handshake`, `:chain_sync`,
      `:keep_alive` (subset → test peers with different capabilities).
    * `:enforce_agency` (default true) — reject messages sent in the wrong
      agency-state (wrong message for current turn) → `{:protocol_violation, _}`.
    * `:max_payload_bytes` (default nil = no limit) — reject oversized payloads
      → `{:size_limit, _}`.
    * `:idle_timeout_ms` (default nil = none) — close if no message arrives in the
      window → `{:timeout, _}`. (Test-scaled; the real node uses ~601-911 s for
      chain-sync StMustReply — we parameterise the magnitude, keep the behaviour.)
    * `:accept_version` / `:magic` — handshake responder config.

  On a violation it stops with an exit reason matching the class of close the real
  node would do (the connection dies), so a monitoring test sees exactly which
  rule it tripped.
  """

  use GenServer

  alias Cardamom.{Channel, Mux.Frame, Mux.SDU}
  alias Cardamom.Protocol.Handshake.Codec, as: HS
  alias Cardamom.Protocol.ChainSync.Codec, as: CS
  alias Cardamom.Protocol.BlockFetch.Codec, as: BF

  @handshake 0
  @chain_sync 2
  @block_fetch 3
  @keep_alive 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)

    state = %{
      channel: channel,
      buffer: <<>>,
      protocols: Keyword.get(opts, :protocols, [:handshake, :chain_sync, :keep_alive]),
      # Pre-built blocks to serve over block-fetch (BlockBuilder results w/ :slot,
      # :envelope). The block-fetch responder serves those in a requested range.
      blocks: Keyword.get(opts, :blocks, []),
      enforce_agency: Keyword.get(opts, :enforce_agency, true),
      max_payload_bytes: Keyword.get(opts, :max_payload_bytes),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms),
      accept_version: Keyword.get(opts, :accept_version, 14),
      magic: Keyword.get(opts, :magic, 2),
      # handshake: refuse instead of accept (a refuse_reason), and/or report the
      # proposed version table to a pid (for asserting what we put on the wire).
      refuse: Keyword.get(opts, :refuse),
      report_to: Keyword.get(opts, :report_to),
      slot: 1_000_000,
      # hash of the last header we emitted, so the next one chains to it (real
      # parent-hash linkage). nil at the start (genesis-like).
      last_hash: nil,
      # per-protocol agency: :client = we (responder) await the client's msg.
      cs_state: :idle,
      # close-verdict: did the client send a chain-sync MsgDone before vanishing?
      # Reported to report_to as {:sim_peer_close, :clean | :dirty} on disconnect.
      saw_done: false
    }

    {:ok, arm_timeout(state), {:continue, :recv}}
  end

  @impl true
  def handle_continue(:recv, state), do: recv_once(state)

  @impl true
  def handle_info(:recv, state), do: recv_once(state)

  def handle_info(:idle_timeout, state) do
    {:stop, {:timeout, :idle}, state}
  end

  defp recv_once(state) do
    case Channel.recv(state.channel, 50) do
      {:ok, bytes} ->
        case drain(%{state | buffer: state.buffer <> bytes}) do
          {:cont, state} ->
            send(self(), :recv)
            {:noreply, arm_timeout(state)}

          {:close, reason, state} ->
            {:stop, reason, state}
        end

      {:error, :timeout} ->
        send(self(), :recv)
        {:noreply, state}

      {:error, _} ->
        # The client's connection dropped. Judge whether it left politely.
        report_close(state)
        {:stop, :normal, state}
    end
  end

  defp report_close(%{report_to: nil}), do: :ok

  defp report_close(state) do
    verdict = if state.saw_done, do: :clean, else: :dirty
    send(state.report_to, {:sim_peer_close, verdict})
  end

  # Pull complete SDUs; route + enforce. Returns {:cont, state} | {:close, reason, state}.
  defp drain(state) do
    case SDU.decode(state.buffer) do
      {:ok, sdu, rest} ->
        case enforce_and_handle(sdu, %{state | buffer: rest}) do
          {:cont, state} -> drain(state)
          close -> close
        end

      {:error, _incomplete} ->
        {:cont, state}
    end
  end

  defp enforce_and_handle(%{protocol_num: num, payload: payload}, state) do
    cond do
      not speaks?(state, num) ->
        {:close, {:protocol_violation, {:unsupported_protocol, num}}, state}

      oversized?(state, payload) ->
        {:close, {:size_limit, byte_size(payload)}, state}

      true ->
        handle(num, payload, state)
    end
  end

  # ---- per-protocol handlers ----

  defp handle(@handshake, payload, state) do
    case HS.decode(payload) do
      {:ok, {:propose_versions, table}, _} ->
        if state.report_to, do: send(state.report_to, {:sim_peer_received_propose, table})
        send_msg(state, @handshake, HS.encode(handshake_reply(state)))
        {:cont, state}

      _ ->
        agency_or_lenient(state, {:bad_handshake_message, payload})
    end
  end

  defp handle(@keep_alive, payload, state) do
    case CBOR.decode(payload) do
      {:ok, [0, cookie], _} when is_integer(cookie) ->
        send_msg(state, @keep_alive, CBOR.encode([1, cookie]))
        {:cont, state}

      _ ->
        # [1,_] is the server's own msg; client sending it = no agency.
        agency_or_lenient(state, {:keep_alive_out_of_agency, payload})
    end
  end

  defp handle(@chain_sync, payload, state) do
    case CS.decode(payload) do
      {:ok, :request_next, _} ->
        slot = state.slot + 1

        # Build a structurally-real Conway header (real bytes, real blake2b-256),
        # chained to the previous header's hash so SimPeer emits a genuinely linked
        # chain — real parent-hash relationships, not random noise.
        hdr =
          Cardamom.Ledger.Conway.HeaderBuilder.build(
            block_number: slot,
            slot: slot,
            prev_hash: state.last_hash
          )

        # tip = [point, block_no], point = [slot, real-header-hash].
        tip = [[slot, %CBOR.Tag{tag: :bytes, value: hdr.hash}], slot]
        send_msg(state, @chain_sync, CS.encode({:roll_forward, hdr.envelope, tip}))

        {:cont, %{state | slot: slot, last_hash: hdr.hash}}

      {:ok, {:find_intersect, points}, _} ->
        # STRICT, like the Haskell relay: every point must be well-formed —
        # [slot, #bytes(hash)] or [] (origin). A point whose hash is a CBOR TEXT
        # string (what a raw Elixir binary encodes to) is a protocol violation; the
        # real Preview relay CLOSES on it (it dropped us on our first resume attempt).
        # SimPeer must reject the same way, so this can't slip through to a live run.
        if Enum.all?(points, &valid_point?/1) do
          send_msg(state, @chain_sync, CS.encode({:intersect_found, [state.slot, <<0::256>>], [state.slot, <<0::256>>]}))
          {:cont, state}
        else
          {:close, {:protocol_violation, {:malformed_intersect_point, points}}, state}
        end

      {:ok, :done, _} ->
        # MsgDone — the client (consumer) is closing chain-sync politely. Record
        # it; the verdict on disconnect will be :clean.
        {:cont, %{state | saw_done: true}}

      {:ok, msg, _} ->
        # Anything else the decoder accepts is a SERVER message
        # (roll_forward/roll_backward/await_reply/intersect_*) — the client has no
        # agency to send it. (request_next/find_intersect/done are the only
        # client-agency messages, handled above.)
        agency_or_lenient(state, {:chain_sync_out_of_agency, msg})

      _ ->
        agency_or_lenient(state, {:bad_chain_sync_message, payload})
    end
  end

  # Block-fetch responder: on a RequestRange, serve a batch of the pre-built blocks
  # whose slot falls in the requested range (StartBatch -> Block xN -> BatchDone), or
  # NoBlocks if none. Blocks come from the `:blocks` opt (BlockBuilder results, each
  # with :slot and :envelope). This is what LogReplayPeer will also do (serve blocks
  # from a list, possibly out of order). Points: [slot, #bytes(hash)].
  defp handle(@block_fetch, payload, state) do
    case BF.decode(payload) do
      {:ok, {:request_range, [from_slot, _], [to_slot, _]}, _} ->
        in_range =
          state.blocks
          |> Enum.filter(fn b -> b.slot >= from_slot and b.slot <= to_slot end)
          |> Enum.sort_by(& &1.slot)

        if in_range == [] do
          send_msg(state, @block_fetch, BF.encode(:no_blocks))
        else
          send_msg(state, @block_fetch, BF.encode(:start_batch))
          for b <- in_range, do: send_msg(state, @block_fetch, BF.encode({:block, b.envelope}))
          send_msg(state, @block_fetch, BF.encode(:batch_done))
        end

        {:cont, state}

      {:ok, :client_done, _} ->
        {:cont, state}

      {:ok, msg, _} ->
        # start_batch/block/no_blocks/batch_done are SERVER messages — client can't send.
        agency_or_lenient(state, {:block_fetch_out_of_agency, msg})

      _ ->
        agency_or_lenient(state, {:bad_block_fetch_message, payload})
    end
  end

  defp handle(_num, _payload, state), do: {:cont, state}

  # A chain-sync point is valid iff it's the origin ([]) or [slot, #bytes(hash)].
  # After CBOR decode, a byte string is %CBOR.Tag{tag: :bytes}; a TEXT string (what a
  # raw binary hash wrongly encodes to) is a plain Elixir binary — that's the
  # violation the real relay rejects.
  defp valid_point?([]), do: true
  defp valid_point?([slot, %CBOR.Tag{tag: :bytes}]) when is_integer(slot), do: true
  defp valid_point?(_), do: false

  defp handshake_reply(%{refuse: reason}) when not is_nil(reason), do: {:refuse, reason}

  defp handshake_reply(state) do
    {:accept_version, state.accept_version,
     %{network_magic: state.magic, initiator_only: false, peer_sharing: 0, query: false}}
  end

  # A message that's only valid from the server, received from the client.
  defp agency_or_lenient(state, reason) do
    if state.enforce_agency do
      {:close, {:protocol_violation, reason}, state}
    else
      {:cont, state}
    end
  end

  # ---- helpers ----

  defp speaks?(state, @handshake), do: :handshake in state.protocols
  defp speaks?(state, @chain_sync), do: :chain_sync in state.protocols
  defp speaks?(state, @block_fetch), do: :block_fetch in state.protocols
  defp speaks?(state, @keep_alive), do: :keep_alive in state.protocols
  defp speaks?(_state, _), do: false

  defp oversized?(%{max_payload_bytes: nil}, _), do: false
  defp oversized?(%{max_payload_bytes: max}, payload), do: byte_size(payload) > max

  defp send_msg(state, num, payload), do: Frame.send_msg(state.channel, num, payload)

  defp arm_timeout(%{idle_timeout_ms: nil} = state), do: state

  defp arm_timeout(%{idle_timeout_ms: ms} = state) do
    if t = Map.get(state, :timer), do: Process.cancel_timer(t)
    Map.put(state, :timer, Process.send_after(self(), :idle_timeout, ms))
  end

end
