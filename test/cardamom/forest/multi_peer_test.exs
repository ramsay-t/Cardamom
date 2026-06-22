defmodule Cardamom.Forest.MultiPeerTest do
  @moduledoc """
  The forest under MANY peers — the question that started this work: spin up N peers
  feeding ONE Forest.Server and assert it stays correct. Each peer is a real pipeline:
  LogReplayPeer (serving authored synthetic chains) → bearer → chain-sync client →
  Forest.Server. Tests convergence (same chain → one tip, no duplicate nodes), fork
  handling (deterministic tie-break regardless of interleaving), and concurrent flood.

  Content is authored via Cardamom.Test.SyntheticChain (real hash-linked headers,
  encoded as RollForward payloads). The forest add is a synchronous call now (the
  backpressure fix), so concurrent feeders serialise correctly through the one server.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Cardamom.{Channel, Connection, ChainSync}
  alias Cardamom.Forest.Server, as: Forest
  alias Cardamom.Test.SyntheticChain

  setup do
    Process.flag(:trap_exit, true)

    # The chain-sync client feeds the Forest.Server under its registered name. The app
    # supervisor runs the real one; steal the name for the test (genesis-rooted, fresh),
    # restore it after — like the backpressure test does.
    real = Process.whereis(Forest)
    if real, do: Process.unregister(Forest)
    {:ok, forest} = Forest.start_link(name: Forest, root: :genesis)

    on_exit(fn ->
      if Process.whereis(Forest) == forest, do: Process.unregister(Forest)
      if Process.alive?(forest), do: Process.exit(forest, :kill)
      if real && Process.alive?(real), do: Process.register(real, Forest)
    end)

    %{forest: forest}
  end

  # One peer pipeline: ReplayPeer (server end) ←→ bearer ←→ chain-sync client.
  # resume: false so the client cold-starts (RequestNext stream), no FindIntersect.
  defp start_peer(payloads, label) do
    {client_end, server_end} = Channel.Test.pair()
    {:ok, _replay} = Cardamom.LogReplayPeer.start_link(channel: server_end, payloads: payloads)
    {:ok, conn} = Connection.start_link(channel: client_end, peer: label)
    {:ok, cs} = ChainSync.Client.start_link(conn: conn, peer: label, resume: false)
    %{conn: conn, cs: cs}
  end

  # node_count includes the :genesis root, so a chain of N distinct headers → N+1 nodes.
  @genesis_root 1

  # Poll the forest until its node_count reaches `n` distinct headers (+ genesis), or
  # timeout — the chain-sync stream is async, so wait rather than sleep blindly.
  defp await_nodes(n, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 3_000
    target = n + @genesis_root

    cond do
      Forest.status().node_count >= target -> :ok
      System.monotonic_time(:millisecond) > deadline -> {:timeout, Forest.status().node_count}
      true -> (Process.sleep(20); await_nodes(n, deadline))
    end
  end

  test "one peer serving a synthetic linked chain → forest tracks it to the right tip" do
    chain = SyntheticChain.chain(8)
    _peer = start_peer(SyntheticChain.payloads(chain), "solo")

    assert :ok = await_nodes(8), "all 8 headers should land in the forest"

    tip = List.last(chain)
    status = Forest.status()
    assert status.tip == SyntheticChain.hash_hex(tip), "tip is the last header of the chain"
    assert status.tip_height == tip.block_number
  end

  test "N honest peers serving the SAME chain → one tip, no duplicate nodes" do
    chain = SyntheticChain.chain(10)
    payloads = SyntheticChain.payloads(chain)

    # Five peers, identical content, all feeding the one forest concurrently.
    for i <- 1..5, do: start_peer(payloads, "same-#{i}")

    # node_count must converge to exactly 10 — NOT 50. Concurrent adds of the same
    # (hash, parent) are idempotent; the forest must dedup, not double-count.
    assert :ok = await_nodes(10)
    status = Forest.status()
    assert status.node_count == 10 + @genesis_root, "same chain from 5 peers → 10 distinct nodes (+genesis), not 50 (idempotent)"
    assert status.tip == SyntheticChain.hash_hex(List.last(chain))
  end

  test "two peers sharing a prefix then FORKING → forest holds both; tip is deterministic" do
    {_prefix, chain_a, chain_b} = SyntheticChain.fork(5, 3)

    start_peer(SyntheticChain.payloads(chain_a), "fork-a")
    start_peer(SyntheticChain.payloads(chain_b), "fork-b")

    # 5 shared + 3 (tail A) + 3 (tail B) = 11 distinct nodes (the prefix is shared).
    assert :ok = await_nodes(11)
    status = Forest.status()
    assert status.node_count == 11 + @genesis_root, "shared prefix counted once; two divergent tails (+genesis)"

    # Both tails are equal length from the same fork point → bump_best's tie-break
    # (height, then hash_key) picks ONE deterministically. It must be one of the two
    # tail tips, and the same one no matter the arrival interleaving.
    tip_a = SyntheticChain.hash_hex(List.last(chain_a))
    tip_b = SyntheticChain.hash_hex(List.last(chain_b))
    assert status.tip in [tip_a, tip_b]
    assert status.tip_height == List.last(chain_a).block_number

    # Determinism: the winner is the larger hash_key (the forest's documented tie-break).
    expected = Enum.max([tip_a, tip_b])
    assert status.tip == expected, "fork tie-break must be deterministic (max hash_key)"
  end

  test "concurrent header flood from many peers → forest stays consistent, no loss" do
    # 8 peers, each a DIFFERENT genesis-rooted chain of 6 → 8 disjoint trees, 48 nodes.
    # The synchronous forest add must serialise all 8 feeders with zero lost/torn state.
    chains = for i <- 1..8, do: SyntheticChain.chain(6, start_slot: i * 100)
    for {chain, i} <- Enum.with_index(chains), do: start_peer(SyntheticChain.payloads(chain), "flood-#{i}")

    assert :ok = await_nodes(48), "all 48 headers from 8 concurrent peers must land"
    assert Forest.status().node_count == 48 + @genesis_root, "no lost or double-counted nodes under concurrency (+genesis)"
  end
end
