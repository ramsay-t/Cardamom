defmodule Cardamom.DataCase do
  @moduledoc """
  Test case for anything touching the durable store.

  ISOLATION: every store-touching test starts from a CLEAN store — all tables
  truncated and the cache wiped in setup. This is the singleton-Repo-friendly
  equivalent of giving each test its own throwaway `forest-<magic>.db`: there is no
  shared *content* between tests, so nothing leaks (the bug that forced earlier
  band-aids). Tests run serially (`async: false`) so the clean slate holds for the
  whole test — including writes from app-singleton processes (Forest.Server,
  ChainSync.Client) that share this one Repo.

  We deliberately do NOT use Sandbox shared-mode: it routes every process through one
  transaction, but app singletons' writes can still escape it and commit, which is
  exactly what leaked between tests before.
  """
  use ExUnit.CaseTemplate

  alias Cardamom.Store.{Cache, Header, Kv, Repo}

  using do
    quote do
      alias Cardamom.Store.Repo
    end
  end

  setup do
    # DRAIN live block handlers FIRST — a continuous-retry handler for an absent-producer block
    # from a prior test would otherwise keep retrying and write into the tables we're about to
    # truncate (a cross-test leak). terminate_all kills each handler (cascading its tx retriers).
    if Process.whereis(Cardamom.Ledger.BlockSupervisor), do: Cardamom.Ledger.BlockSupervisor.terminate_all()
    if Process.whereis(Cardamom.Ledger.HeaderSupervisor), do: Cardamom.Ledger.HeaderSupervisor.terminate_all()

    # Clean slate: truncate every store table and clear the cache. Each test thus
    # begins with an empty store, regardless of what ran before.
    Repo.delete_all(Header)
    Repo.delete_all(Kv)
    Repo.delete_all(Cardamom.Store.Block)
    Repo.delete_all(Cardamom.Store.Txo)
    Repo.delete_all(Cardamom.Store.MempoolTxo)
    Repo.delete_all(Cardamom.Store.MempoolGraveyard)
    Repo.delete_all(Cardamom.Store.MempoolTxInput)
    Repo.delete_all(Cardamom.Store.Peer)
    Cache.delete_all()
    # Clear the block-fetch peer rotation so a prior test's (now-dead) peer pids
    # don't linger in ChainStore's round-robin.
    Cardamom.ChainStore.reset_peers()
    :ok
  end
end
