defmodule Cardamom.TxSubmission.ClientTest do
  @moduledoc """
  TxSubmission2 (proto 4) client, BOTH roles (full node someday).

  RECEIVER (fills OUR mempool — the observe path): we drive the pull loop — send
  RequestTxIds, the peer replies with (txid, size) announcements, we RequestTxs the ones
  we don't have, decode each ReplyTxs body and put_mempool_tx. This is how we observe a
  peer's mempool.

  SUBMITTER (we offer txs): the peer sends US RequestTxIds → we reply from our mempool;
  RequestTxs → we reply with bodies.

  Driven over a bearer with scripted proto-4 messages.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{Channel, Connection, ChainStore, Mux.Frame}
  alias Cardamom.TxSubmission.Client
  alias Cardamom.Protocol.TxSubmission.Codec, as: TS
  alias Cardamom.Ledger.Conway.Tx

  @tx_submission 4

  # A real standalone tx body (block 3's tx) — gives a genuine txid + outputs.
  defp real_tx_body do
    raw = File.read!(Path.join([__DIR__, "..", "..", "fixtures", "blocks", "block-3.hex"]))
          |> String.trim() |> Base.decode16!(case: :lower)
    {:ok, [tx]} = Tx.txs_in(raw)
    # Re-derive the standalone body bytes: txs_in carved them; we re-encode the body map
    # for the test. (The txid in the mempool will match decode_tx of these bytes.)
    {tx, body_bytes_of(raw)}
  end

  defp body_bytes_of(block_raw) do
    {:ok, [_era, inner], _} = CBOR.decode(block_raw)
    [_hdr, [body | _] | _] = inner
    CBOR.encode(body)
  end

  defp start_stack do
    {client_end, peer_end} = Channel.Test.pair()
    {:ok, conn} = Connection.start_link(channel: client_end, peer: "ts")
    {:ok, client} = Client.start_link(conn: conn, peer: "ts", role: :receiver, request_amount: 10)
    {client, peer_end}
  end

  defp send_ts(pe, msg), do: Frame.send_msg(pe, @tx_submission, TS.encode(msg))

  describe "receiver role — pull txs INTO our mempool" do
    test "on start (receiver) the client sends Init then RequestTxIds" do
      {_c, pe} = start_stack()

      assert {:ok, p1, _, buf} = Frame.recv_msg(pe, <<>>, 1_000)
      assert {:ok, :init, ""} = TS.decode(p1)
      assert {:ok, p2, _, _} = Frame.recv_msg(pe, buf, 1_000)
      assert {:ok, {:request_tx_ids, _blocking, _ack, 10}, ""} = TS.decode(p2)
    end

    test "announced ids → the client requests them → replied bodies land in the mempool" do
      {tx, body} = real_tx_body()
      {_c, pe} = start_stack()
      # drain Init + first RequestTxIds
      {:ok, _, _, b1} = Frame.recv_msg(pe, <<>>, 1_000)
      {:ok, _, _, _} = Frame.recv_msg(pe, b1, 1_000)

      # Peer announces the tx (txid + size).
      send_ts(pe, {:reply_tx_ids, [{tx.txid, byte_size(body)}]})

      # Client should now RequestTxs for that id.
      assert {:ok, req, _} = recv_match(pe, fn m -> match?({:request_txs, _}, m) end)
      assert {:request_txs, [reqid]} = req
      assert reqid == tx.txid

      # Peer replies with the body → client decodes + put_mempool_tx.
      send_ts(pe, {:reply_txs, [body]})

      wait_until(fn -> ChainStore.mempool_txo(tx.txid, 0) != nil end)
      assert %{spent_by: nil} = ChainStore.mempool_txo(tx.txid, 0)
    end

    test "the client does NOT re-request a tx already in the mempool" do
      {tx, body} = real_tx_body()
      # Pre-seed: the tx is already pending.
      {:ok, decoded} = Tx.decode_tx(body)
      :ok = ChainStore.put_mempool_tx(decoded)

      {_c, pe} = start_stack()
      {:ok, _, _, b1} = Frame.recv_msg(pe, <<>>, 1_000)
      {:ok, _, _, _} = Frame.recv_msg(pe, b1, 1_000)

      send_ts(pe, {:reply_tx_ids, [{tx.txid, byte_size(body)}]})

      # It should request NOTHING (we already have it) — request_txs absent / empty.
      case recv_match(pe, fn m -> match?({:request_txs, _}, m) end, 300) do
        {:error, :timeout} -> :ok
        {:ok, {:request_txs, ids}, _} -> assert ids == [], "must not re-request known txs"
      end
    end
  end

  describe "submitter role — reply from our mempool when the peer asks" do
    test "peer RequestTxIds → we reply with our mempool's (txid, size)" do
      {tx, body} = real_tx_body()
      {:ok, decoded} = Tx.decode_tx(body)
      :ok = ChainStore.put_mempool_tx(decoded)

      {client_end, peer_end} = Channel.Test.pair()
      {:ok, conn} = Connection.start_link(channel: client_end, peer: "ts-sub")
      {:ok, _c} = Client.start_link(conn: conn, peer: "ts-sub", role: :submitter)

      send_ts(peer_end, {:request_tx_ids, true, 0, 5})

      assert {:ok, {:reply_tx_ids, ids}, _} = recv_match(peer_end, fn m -> match?({:reply_tx_ids, _}, m) end)
      assert Enum.any?(ids, fn {id, _sz} -> id == tx.txid end), "we announce what we hold"
    end

    test "peer RequestTxs → we reply (announce-only stub: no bodies served yet)" do
      {client_end, peer_end} = Channel.Test.pair()
      {:ok, conn} = Connection.start_link(channel: client_end, peer: "ts-sub2")
      {:ok, _c} = Client.start_link(conn: conn, peer: "ts-sub2", role: :submitter)

      send_ts(peer_end, {:request_txs, [<<1::256>>]})

      # We reply ReplyTxs — currently empty (serving bodies needs raw-tx storage, a
      # documented stub). The point: we ANSWER, we don't hang or crash.
      assert {:ok, {:reply_txs, bodies}, _} = recv_match(peer_end, fn m -> match?({:reply_txs, _}, m) end)
      assert bodies == []
    end
  end

  describe "tolerance (Harvard boundary)" do
    test "init / done / garbage on the wire don't crash the client" do
      {c, pe} = start_stack()
      {:ok, _, _, b1} = Frame.recv_msg(pe, <<>>, 1_000)
      {:ok, _, _, _} = Frame.recv_msg(pe, b1, 1_000)

      send_ts(pe, :init)
      send_ts(pe, :done)
      :ok = Frame.send_msg(pe, @tx_submission, <<0xFF, 0xFF, 0xFF>>)
      Process.sleep(50)
      assert Process.alive?(c)
    end

    test "an undecodable tx body in ReplyTxs is skipped, not crashed" do
      {c, pe} = start_stack()
      {:ok, _, _, b1} = Frame.recv_msg(pe, <<>>, 1_000)
      {:ok, _, _, _} = Frame.recv_msg(pe, b1, 1_000)

      # A reply whose "body" is not a valid tx → decode_tx errors → skipped.
      send_ts(pe, {:reply_txs, [<<0xFF, 0x00, 0x01>>]})
      Process.sleep(50)
      assert Process.alive?(c), "a bad tx body must not crash the receiver"
    end
  end

  # ---- helpers ----

  defp recv_match(pe, pred, timeout \\ 1_000, buf \\ <<>>) do
    case Frame.recv_msg(pe, buf, timeout) do
      {:ok, payload, _sdu, rest} ->
        case TS.decode(payload) do
          {:ok, msg, _} -> if pred.(msg), do: {:ok, msg, rest}, else: recv_match(pe, pred, timeout, rest)
          _ -> recv_match(pe, pred, timeout, rest)
        end

      other ->
        other
    end
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      tries <= 0 -> flunk("condition not met")
      fun.() -> :ok
      true -> (Process.sleep(20); wait_until(fun, tries - 1))
    end
  end
end
