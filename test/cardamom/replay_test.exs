defmodule Cardamom.ReplayTest do
  @moduledoc """
  The from-genesis REPLAY DRIVER: feed stored blocks in SLOT ORDER through the real
  synchronous extraction path (extract_block_sync → the BlockHandler gate), rebuilding
  derived state deterministically. Validates the reward engine (via the withdrawal oracle)
  and supplies the contiguous fold the leader-election oracle needs.

  Under test (against synthetic BlockBuilder blocks — no live network, no DB wipe):
    * in-order fold: every stored block extracted, in slot order, marked processed;
    * resumability: a second run resumes past already-processed blocks (txo_processed = the
      checkpoint), doing no redundant work;
    * HALT ON REJECT: a block the gate rejects stops the driver at that block with the verdict,
      leaving it unprocessed (stop-and-fix) — the driver does NOT plough on;
    * telemetry: per-run progress is reported.
  """
  use Cardamom.DataCase, async: false
  import Ecto.Query

  alias Cardamom.{ChainStore, Replay}
  alias Cardamom.Ledger.Conway.BlockBuilder
  alias Cardamom.Store.Block, as: BlockRow

  # Store a block row exactly as the fetch path would (raw bytes, unprocessed), so replay finds it.
  defp store(slot, opts \\ []) do
    b = BlockBuilder.build([slot: slot, block_number: slot] ++ opts)

    {:ok, _} =
      %BlockRow{}
      |> BlockRow.changeset(%{
        hash: b.hash,
        slot: slot,
        block_no: slot,
        tx_count: b.tx_count,
        raw: b.raw,
        txo_processed: false
      })
      |> Repo.insert()

    b
  end

  defp processed?(hash), do: Repo.get(BlockRow, hash).txo_processed
  defp pending_count, do: Repo.aggregate(from(b in BlockRow, where: b.txo_processed == false), :count)

  test "in-order fold: all stored blocks extracted in slot order and marked processed" do
    for s <- [30, 10, 20], do: store(s)

    assert {:ok, %{processed: 3, halted: nil}} = Replay.run()
    assert pending_count() == 0
  end

  test "reports the slot order it visited (deterministic, ascending)" do
    for s <- [50, 5, 25], do: store(s)
    {:ok, %{visited_slots: slots}} = Replay.run(collect_slots: true)
    assert slots == [5, 25, 50]
  end

  test "resumable: a second run does no work when everything is already processed" do
    for s <- [10, 20], do: store(s)
    assert {:ok, %{processed: 2}} = Replay.run()
    assert {:ok, %{processed: 0}} = Replay.run(), "already-processed blocks are skipped"
  end

  test "HALT on a gate REJECT: driver stops at the offending block, leaves it unprocessed" do
    # An empty conformant block, then a block whose single tx violates value conservation
    # (a withdrawal of 5000 but only 4000 fee → consumed ≠ produced), then a block AFTER it.
    good = store(10)
    _bad = store(20, bodies: [%{2 => 4000, 5 => %{%CBOR.Tag{tag: :bytes, value: <<0xE0, 1::224>>} => 5000}}])
    _after = store(30)

    assert {:ok, %{processed: 1, halted: halt}} = Replay.run()
    assert %{slot: 20, verdict: %{decision: :reject}} = halt
    assert processed?(good.hash), "the good block before the reject is committed"
    # the reject block and everything after it stay unprocessed (stop-and-fix)
    assert pending_count() == 2
  end

  test "emits [:cardamom, :replay, :progress] telemetry" do
    for s <- [10, 20], do: store(s)
    id = make_ref()
    me = self()

    :telemetry.attach(id, [:cardamom, :replay, :progress],
      fn _e, meas, meta, _ -> send(me, {:progress, meas, meta}) end, nil)

    try do
      Replay.run(progress_every: 1)
    after
      :telemetry.detach(id)
    end

    assert_received {:progress, %{processed: _}, _}
  end
end
