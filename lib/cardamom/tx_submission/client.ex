defmodule Cardamom.TxSubmission.Client do
  @moduledoc """
  Drives the TxSubmission2 mini-protocol (4) — BOTH roles (full node someday).

  PULL-BASED and asymmetric (see reference_txsubmission_lifecycle): the RECEIVER pulls
  txs from the SUBMITTER. There is no tx-removal message — mempool exit is learned from
  block-fetch (`:in_block` / `:invalid`) or our own policy (`:inputs_spent` / `:expired`),
  never from this protocol.

    * `role: :receiver` — fills OUR mempool (the observe path). We send Init then loop:
      RequestTxIds → on ReplyTxIds, RequestTxs for the ids we don't already hold → on
      ReplyTxs, decode each body and ChainStore.put_mempool_tx. Re-request only unknowns.
    * `role: :submitter` — we offer txs. On the peer's RequestTxIds we reply from our
      mempool's (txid, size); on RequestTxs we reply with the bodies.

  A process holding the bearer; registers for proto 4. Tx bodies are opaque on the wire
  (Harvard boundary); decoding to a tx happens via the ledger (`Conway.Tx`).

  Opts: `:conn` (bearer), `:peer` (label), `:role` (:receiver | :submitter),
  `:request_amount` (receiver: how many ids to ask for; default 10).
  """
  use GenServer
  require Logger

  alias Cardamom.Protocol.TxSubmission.Codec
  alias Cardamom.Ledger.Conway.Tx

  @tx_submission 4
  @default_amount 10

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    Process.link(conn)
    Process.flag(:trap_exit, true)
    :ok = Cardamom.Connection.register(conn, @tx_submission)

    state = %{
      conn: conn,
      peer: Keyword.get(opts, :peer, "loopback"),
      role: Keyword.get(opts, :role, :receiver),
      amount: Keyword.get(opts, :request_amount, @default_amount),
      # A peer that gossips a DEFINITELY-invalid tx loses reputation (ChainStore.record_peer),
      # keyed by its address. Absent peer_addr → just log (we still don't store the junk).
      peer_addr: Keyword.get(opts, :peer_addr)
    }

    # Receiver drives the loop: announce Init, then ask for ids. Submitter waits to be
    # asked (the peer holds agency in that direction).
    if state.role == :receiver do
      send_msg(state, :init)
      send_msg(state, {:request_tx_ids, true, 0, state.amount})
    end

    {:ok, state}
  end

  @impl true
  def handle_info({:sdu, @tx_submission, payload}, state) do
    # RAW bytes off the wire, BEFORE decode — the live-debug capture (matches chain_sync).
    Logger.debug(fn -> "tx_submission raw payload: " <> Base.encode16(payload, case: :lower) end)

    case Codec.decode(payload) do
      {:ok, msg, _rest} ->
        emit_in(msg, state)
        {:noreply, on_msg(msg, state)}

      {:error, reason} ->
        Logger.warning("tx_submission decode error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  defp emit_in(msg, state) do
    Logger.info("tx_submission #{state.peer} <- #{inbound_label(msg)}")

    :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{
      protocol: "tx_submission",
      msg: inbound_label(msg),
      peer: state.peer
    })
  end

  defp inbound_label({:request_tx_ids, blk, ack, req}), do: "RequestTxIds(blocking=#{blk}, ack=#{ack}, req=#{req})"
  defp inbound_label({:reply_tx_ids, ids}), do: "ReplyTxIds(#{length(ids)})"
  defp inbound_label({:request_txs, ids}), do: "RequestTxs(#{length(ids)})"
  defp inbound_label({:reply_txs, txs}), do: "ReplyTxs(#{length(txs)})"
  defp inbound_label(:init), do: "Init"
  defp inbound_label(:done), do: "Done"
  defp inbound_label(other), do: inspect(other)

  # ---- receiver side ----

  # Peer announced (txid, size) pairs. Request the ones we don't already hold.
  defp on_msg({:reply_tx_ids, ids}, %{role: :receiver} = state) do
    wanted =
      ids
      |> Enum.map(fn {txid, _size} -> txid end)
      |> Enum.reject(&already_have?/1)

    send_msg(state, {:request_txs, wanted})
    state
  end

  # Peer sent tx bodies. Decode → PHASE-1 VALIDATE → add valid ones to the mempool. We do
  # not gossip onward / store junk; a peer that sends a DEFINITELY-invalid tx loses
  # reputation. An :unverifiable tx (input we haven't synced) is held without penalty.
  defp on_msg({:reply_txs, txs}, %{role: :receiver} = state) do
    Enum.each(txs, fn body ->
      case Tx.decode_tx(body) do
        {:ok, tx} -> ingest_tx(tx, state)
        {:error, reason} ->
          Logger.warning("tx_submission: undecodable tx body: #{inspect(reason)}")
          # An undecodable body is structurally bad — the peer sent garbage.
          penalise(state, :sent_undecodable_tx)
      end
    end)

    # Keep pulling.
    send_msg(state, {:request_tx_ids, true, length(txs), state.amount})
    state
  end

  # ---- submitter side ----

  # Peer asks for ids — reply from our mempool's distinct (txid, size).
  defp on_msg({:request_tx_ids, _blocking, _ack, req}, %{role: :submitter} = state) do
    ids =
      our_mempool_ids()
      |> Enum.take(req)

    send_msg(state, {:reply_tx_ids, ids})
    state
  end

  # Peer asks for bodies — reply with the raw bytes we have for those ids.
  defp on_msg({:request_txs, txids}, %{role: :submitter} = state) do
    bodies = Enum.flat_map(txids, fn txid -> our_tx_body(txid) end)
    send_msg(state, {:reply_txs, bodies})
    state
  end

  defp on_msg(:init, state), do: state
  defp on_msg(:done, state), do: state
  defp on_msg(_other, state), do: state

  # ---- mempool helpers ----

  # Phase-1 validate, then route by verdict: :ok → mempool; {:rejected,_} → drop + ding the
  # peer (it gossiped junk); {:unverifiable,_} → hold without penalty (our view is partial,
  # not the peer's fault). No store running (bare tests) → just decode + telemetry.
  defp ingest_tx(tx, state) do
    verdict = if store_running?(), do: Cardamom.ChainStore.validate_tx_phase1(tx), else: :ok

    case verdict do
      :ok ->
        if store_running?(), do: Cardamom.ChainStore.put_mempool_tx(tx)
        emit_tx("MempoolTx", tx, state)

      {:rejected, reason} ->
        Logger.info("tx_submission #{state.peer}: REJECTED tx (#{inspect(reason)}) — not stored")
        emit_tx("RejectedTx", tx, state)
        penalise(state, :sent_invalid_tx)

      {:unverifiable, _missing} ->
        # We can't see this tx's inputs yet (unsynced). Don't store, don't penalise.
        emit_tx("UnverifiableTx", tx, state)
    end
  end

  defp emit_tx(msg, tx, state) do
    :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, %{
      protocol: "tx_submission",
      msg: msg,
      peer: state.peer,
      txid: Base.encode16(tx.txid, case: :lower)
    })
  end

  # Dock a peer's reputation for sending something definitively invalid — only when we know
  # the peer's address and the store is running. Never for :unverifiable.
  defp penalise(%{peer_addr: %{host: host, port: port}}, event) do
    if store_running?(), do: Cardamom.ChainStore.record_peer(%{host: host, port: port, event: event})
  end

  defp penalise(_state, _event), do: :ok

  defp already_have?(txid) do
    store_running?() and Cardamom.ChainStore.mempool_txo(txid, 0) != nil
  end

  # Distinct (txid, size) of what we hold pending. size = byte_size of the stored output
  # raw is not the tx size; for a real submitter we'd keep the tx body — for now we
  # report ids we know with a best-effort size of 0 (the receiver re-derives on fetch).
  defp our_mempool_ids do
    if store_running?() do
      Cardamom.ChainStore.unspent_mempool_txids()
      |> Enum.map(fn txid -> {txid, 0} end)
    else
      []
    end
  end

  # STUB: serving tx BODIES needs the raw tx bytes, which we don't yet store
  # (put_mempool_tx extracts outputs to mempool_txos and discards the body). So the
  # submitter can ANNOUNCE txids but not yet SERVE them — it replies with no bodies.
  # Completing this means storing the raw tx (a mempool_txs-by-txid table); deferred
  # while the node is observer-first (the RECEIVER path is the one that matters now).
  defp our_tx_body(_txid), do: []

  defp store_running?, do: Process.whereis(Cardamom.Store.Repo) != nil

  defp send_msg(state, msg),
    do: Cardamom.Connection.send_frame(state.conn, @tx_submission, Codec.encode(msg))
end
