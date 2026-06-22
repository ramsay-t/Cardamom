defmodule Cardamom.Test.SyntheticChain do
  @moduledoc """
  Authoring helper for repeatable, synthetic chain-sync content — for the multi-peer
  forest tests. Builds REAL, hash-linked Conway headers via `HeaderBuilder` (so parent
  hashes and header hashes are genuine blake2b, not hand-faked), then encodes each as a
  `roll_forward` chain-sync payload — the byte sequence a relay would send, suitable as
  `Cardamom.LogReplayPeer`'s `:payloads`.

  The output is "synthetic recorded bytes": authored with the builder (which alone can
  compute the linked hashes), captured as wire payloads, served verbatim by ReplayPeer.
  SimPeer is the *interactive* protocol peer (handshake/keep-alive/agency); this is for
  *content* — what the forest must converge on.

  A chain is a list of header maps (`%{raw:, hash:, slot:, block_number:, envelope:}`),
  each linked to the previous by `prev_hash`. `payloads/1` turns a chain into the
  RollForward payload list; `fork/3` builds a shared prefix then two divergent tails.
  """

  alias Cardamom.Ledger.Conway.HeaderBuilder
  alias Cardamom.Protocol.ChainSync.Codec, as: CS

  @doc """
  Build a linked chain of `n` headers starting at `start_slot` (default 1), each chained
  to the previous via prev_hash. `:from` seeds the first header's prev_hash (for a fork
  tail that continues from a shared prefix); nil → a genesis-rooted chain.
  Returns the list of header maps (slot == block_number for simplicity).
  """
  def chain(n, opts \\ []) do
    start_slot = Keyword.get(opts, :start_slot, 1)
    from = Keyword.get(opts, :from, nil)

    {headers, _last} =
      Enum.map_reduce(0..(n - 1), from, fn i, prev ->
        slot = start_slot + i
        h = HeaderBuilder.build(block_number: slot, slot: slot, prev_hash: prev)
        {h, h.hash}
      end)

    headers
  end

  @doc """
  A shared prefix of `prefix_len` headers, then two divergent tails of `tail_len` each.
  Returns `{prefix, chain_a, chain_b}` where chain_a/chain_b are the FULL chains
  (prefix ++ own tail) — i.e. what each peer would serve. The two tails branch from the
  same parent (the prefix tip) but have different content (different slots), so their
  header hashes differ → a genuine fork in the forest.
  """
  def fork(prefix_len, tail_len, opts \\ []) do
    start_slot = Keyword.get(opts, :start_slot, 1)
    prefix = chain(prefix_len, start_slot: start_slot)
    tip = List.last(prefix)

    # Two tails from the same parent. Tail B is slot-shifted so its headers differ from
    # tail A's (distinct hashes) while both branch off the shared prefix tip.
    tail_a = chain(tail_len, start_slot: start_slot + prefix_len, from: tip.hash)
    tail_b = chain(tail_len, start_slot: start_slot + prefix_len + 1000, from: tip.hash)

    {prefix, prefix ++ tail_a, prefix ++ tail_b}
  end

  @doc """
  Encode a chain (list of header maps) as the `roll_forward` chain-sync payloads a relay
  sends — the `:payloads` list for `Cardamom.LogReplayPeer`. The tip in each message is
  that header's own point (a self-describing per-message tip — enough for the client to
  decode and feed the forest; the forest, not the stream, judges the real tip).
  """
  def payloads(chain) do
    Enum.map(chain, fn h ->
      tip = [[h.slot, %CBOR.Tag{tag: :bytes, value: h.hash}], h.block_number]
      CS.encode({:roll_forward, h.envelope, tip})
    end)
  end

  @doc "The hex hash of a header (forest keys nodes by lowercase-hex hash)."
  def hash_hex(%{hash: hash}), do: Base.encode16(hash, case: :lower)
end
