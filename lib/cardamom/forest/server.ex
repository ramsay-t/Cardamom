defmodule Cardamom.Forest.Server do
  @moduledoc """
  A process that owns a `Cardamom.Forest` and the tip pointer in its state.
  Headers are fed to it as `(hash, parent_hash)` pairs — that's all the structure
  needs; full header decode lives in the ledger layer, and the network layer
  (`Connection`) calls `add_header/3` after extracting the point.

  Emits `[:cardamom, :forest, :header]` telemetry on each add (so the UI/log show
  the cursor advancing) and `[:cardamom, :forest, :rollback]` on rollback.

  Trust-everything: every header is filed; nothing validated or pruned yet.
  """

  use GenServer
  require Logger

  alias Cardamom.Forest

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, gen_opts(name))
  end

  defp gen_opts(nil), do: []
  defp gen_opts(name), do: [name: name]

  # ---- API ----

  @doc """
  Feed a header given as its hash and parent hash.

  SYNCHRONOUS (a `call`, not a `cast`) by deliberate design: this is the
  backpressure that bounds the mailbox under fan-out. The chain-sync pull loop
  feeds the forest BEFORE requesting the next header, so a synchronous add makes
  "stop pulling until we've handled the last one" literally true end-to-end — each
  peer rendezvouses with the forest before pulling again, capping in-flight writes
  at one per peer. A wedged forest correctly stalls ingest rather than letting the
  request loop race unboundedly ahead. (See ForestBackpressureTest.)
  """
  def add_header(server \\ __MODULE__, hash, parent_hash) do
    GenServer.call(server, {:add, hash, parent_hash})
  end

  @doc "Current tip hash."
  def tip(server \\ __MODULE__), do: GenServer.call(server, :tip)

  @doc """
  Move the tip back to `point` (rollback). Synchronous for the same reason as
  `add_header/3`: the chain-sync loop must handle the roll-backward before pulling
  the next message.
  """
  def rollback(server \\ __MODULE__, point), do: GenServer.call(server, {:rollback, point})

  @doc "A snapshot: tip, its height, node count."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "A bounded view of the tip neighbourhood (spine + forks) for the live UI."
  def view(server \\ __MODULE__, depth \\ 12), do: GenServer.call(server, {:view, depth})

  @doc "Connected leaves (open tips), best-first — the candidate resume points."
  def leaves(server \\ __MODULE__), do: GenServer.call(server, :leaves)

  # ---- GenServer ----

  @impl true
  def init(opts) do
    # Prepare the forest FROM BOOT, anchored at where we left off. Precedence:
    #   explicit :root opt  >  the durable stored tip  >  genesis (cold start).
    # Anchoring at the stored tip (a hex hash) means the forest knows its resume
    # point before any network activity; the chain-sync client offers it via
    # FindIntersect and the forest tracks forward from there (we don't reload all
    # of history — matches "best leaf" resume). last_tip is primed to the seed so we
    # don't redundantly re-persist it on the first add.
    {forest, last_tip} =
      case {opts[:root], boot_tip()} do
        {root, _} when not is_nil(root) -> {Forest.new(root), nil}
        {nil, {tip, height}} -> {Forest.new_at(tip, height), tip}
        {nil, nil} -> {Forest.new(), nil}
      end

    {:ok, %{forest: forest, last_tip: last_tip}}
  end

  # The durable resume anchor as `{hex_hash, height}`, or nil for a cold start / no
  # store. The resume tip is NOT genesis — it's block N — so we seed it at its real
  # height (the stored header's block_no), NOT 0, else the forest forgets the chain's
  # height and the next block connects at 1. Best-effort: absent in bare unit tests.
  defp boot_tip do
    with true <- Process.whereis(Cardamom.Store.Repo) != nil,
         hash when is_binary(hash) <- Cardamom.ChainStore.get_tip(),
         %Cardamom.Store.Header{block_no: h} when is_integer(h) <-
           Cardamom.ChainStore.get_header(hash) do
      {Base.encode16(hash, case: :lower), h}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @impl true
  def handle_call({:add, hash, parent}, _from, %{forest: f} = state) do
    f = Forest.add(f, %{hash: hash, parent_hash: parent})
    tip = Forest.tip(f)

    :telemetry.execute([:cardamom, :forest, :header], %{}, %{
      hash: hash,
      parent: parent,
      tip: tip,
      tip_height: Forest.height(f, tip)
    })

    # The forest is the authority on the tip — persist its JUDGED tip as the durable
    # resume anchor (NOT the raw chain-sync stream's latest, which may be a fork the
    # forest doesn't believe). Only on CHANGE (the tip moves every header; we don't
    # hammer the store with no-op writes). Best-effort; absent in bare unit tests.
    {:reply, :ok, %{state | forest: f} |> maybe_persist_tip(tip)}
  end

  def handle_call({:rollback, point}, _from, %{forest: f} = state) do
    f = Forest.rollback(f, point)
    tip = Forest.tip(f)
    :telemetry.execute([:cardamom, :forest, :rollback], %{}, %{point: point, tip: tip})
    {:reply, :ok, %{state | forest: f} |> maybe_persist_tip(tip)}
  end

  @impl true
  def handle_call(:tip, _from, %{forest: f} = state), do: {:reply, Forest.tip(f), state}

  def handle_call(:status, _from, %{forest: f} = state) do
    tip = Forest.tip(f)
    {:reply, %{tip: tip, tip_height: Forest.height(f, tip), node_count: map_size(f.parents)}, state}
  end

  def handle_call({:view, depth}, _from, %{forest: f} = state),
    do: {:reply, Forest.view(f, depth), state}

  def handle_call(:leaves, _from, %{forest: f} = state),
    do: {:reply, Forest.leaves(f), state}

  # Persist the tip to ChainStore only when it actually changed. The forest's tip is
  # a hex hash (or the :genesis atom for an empty forest — never persist that, it's
  # not a resume point). Store keys headers by BINARY hash, so decode hex→binary.
  defp maybe_persist_tip(%{last_tip: tip} = state, tip), do: state

  defp maybe_persist_tip(state, tip) do
    with true <- is_binary(tip),
         {:ok, bin} <- Base.decode16(tip, case: :lower),
         true <- store_running?() do
      Cardamom.ChainStore.put_tip(bin)
    end

    %{state | last_tip: tip}
  rescue
    _ -> %{state | last_tip: tip}
  end

  defp store_running?, do: Process.whereis(Cardamom.Store.Repo) != nil
end
