defmodule Cardamom.Ledger.EpochBoundaryWiringTest do
  @moduledoc """
  The NEWEPOCH wiring through the REAL block pipeline (BlockHandler → apply_ledger_deltas →
  EpochTransition): structurally-real Conway blocks (BlockBuilder) processed across an epoch
  boundary must bootstrap, then fire the transition — including on an EMPTY block, which is the
  common shape of the first block of an epoch. Rollback of the boundary block must restore the
  pre-boundary ledger (the journal inverts the transition like any delta).
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Conway.BlockBuilder

  # Small epochs so the test crosses boundaries in a handful of slots.
  @params %{
    epoch_length: 100,
    active_slots_coeff: {1, 20},
    max_lovelace_supply: 45_000_000_000_000_000,
    security_param: 432,
    a0: {3, 10},
    nopt: 150,
    rho: {3, 1000},
    tau: {1, 5}
  }

  setup do
    Application.put_env(:cardamom, :epoch_params, @params)
    on_exit(fn -> Application.delete_env(:cardamom, :epoch_params) end)
    :ok
  end

  defp process(slot) do
    block = BlockBuilder.build(slot: slot, tx_count: 0)
    assert :ok = ChainStore.process_block(block.raw, slot)
    block
  end

  test "first block bootstraps last_epoch; crossing a boundary advances it and rotates SNAP" do
    process(50)
    assert ChainStore.ledger_read(:epoch, :last_epoch) == 0
    assert ChainStore.ledger_read(:snapshot, :mark) == nil, "bootstrap is not a transition"

    # EMPTY block crossing into epoch 1 — the transition must still fire.
    process(150)
    assert ChainStore.ledger_read(:epoch, :last_epoch) == 1
    assert %{stake: %{}} = ChainStore.ledger_read(:snapshot, :mark), "SNAP took a (empty) mark"
    assert ChainStore.ledger_read(:snapshot, :fee_ss) == 0
    assert ChainStore.ledger_read(:snapshot, :go) == nil, "no go until three boundaries in"
  end

  test "a same-epoch block after the boundary does NOT re-fire the transition" do
    process(50)
    process(150)
    mark = ChainStore.ledger_read(:snapshot, :mark)

    process(160)
    assert ChainStore.ledger_read(:epoch, :last_epoch) == 1
    assert ChainStore.ledger_read(:snapshot, :mark) == mark, "mark untouched within the epoch"
  end

  test "rolling back the boundary block restores the pre-boundary ledger via the journal" do
    process(50)
    process(150)
    assert ChainStore.ledger_read(:epoch, :last_epoch) == 1

    # the boundary block's delta is journalled at slot 150; roll the ledger back below it
    ChainStore.ledger_rollback(149)

    assert ChainStore.ledger_read(:epoch, :last_epoch) == 0
    assert ChainStore.ledger_read(:snapshot, :mark) == nil, "SNAP rotation undone"
    assert ChainStore.ledger_read(:snapshot, :fee_ss) == nil
  end

  test "skipped epochs (no blocks in one) catch up: each crossed boundary transitions once" do
    process(50)
    # next block lands in epoch 3 — epochs 1, 2 AND 3 must each get a transition
    process(350)
    assert ChainStore.ledger_read(:epoch, :last_epoch) == 3
    # three rotations of empty marks: mark/set/go all present (as empty snapshots)
    assert %{stake: %{}} = ChainStore.ledger_read(:snapshot, :go)
  end
end
