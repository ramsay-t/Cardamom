defmodule Cardamom.Channel.Test do
  @moduledoc """
  In-memory `Cardamom.Channel` for tests: a connected pair of endpoints backed by
  a process, no socket. Bytes written at one end are readable at the other.

  Used to drive a protocol FSM against a simulated peer entirely in-process —
  deterministic, fast, CI-able. `pair/0` returns `{client_end, server_end}`; each
  end is a `{Cardamom.Channel.Test, ref}` usable via `Cardamom.Channel`.
  """

  @behaviour Cardamom.Channel

  use GenServer

  defstruct [:pid, :side]

  # ---- construction ----

  @doc "Create a connected pair: `{client_end, server_end}`."
  def pair do
    {:ok, pid} = GenServer.start_link(__MODULE__, :ok)
    client = {__MODULE__, %__MODULE__{pid: pid, side: :a}}
    server = {__MODULE__, %__MODULE__{pid: pid, side: :b}}
    {client, server}
  end

  # ---- Channel behaviour ----

  @impl Cardamom.Channel
  def send(%__MODULE__{pid: pid, side: side}, bytes) do
    GenServer.call(pid, {:send, side, IO.iodata_to_binary(bytes)})
  end

  @impl Cardamom.Channel
  def recv(%__MODULE__{pid: pid, side: side}, timeout) do
    GenServer.call(pid, {:recv, side}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    # The far end / channel process is gone — a closed channel, like a real
    # socket returning {:error, :closed}. Surface it, don't propagate the exit.
    :exit, _ -> {:error, :closed}
  end

  @impl Cardamom.Channel
  def close(%__MODULE__{pid: pid}) do
    # Graceful close: mark closed but let the peer DRAIN already-sent bytes before
    # recv reports {:error, :closed} — mirrors a flushing socket close, so a final
    # MsgDone sent just before close is still delivered, not dropped.
    if Process.alive?(pid), do: GenServer.call(pid, :close)
    :ok
  catch
    :exit, _ -> :ok
  end

  # ---- GenServer: two buffers + a parked reader per side ----
  # Writing to side :a appends to the buffer that side :b reads, and vice-versa.

  @impl true
  def init(:ok) do
    {:ok, %{buf: %{a: <<>>, b: <<>>}, waiting: %{a: nil, b: nil}, closed: false}}
  end

  @impl true
  def handle_call({:send, from_side, bytes}, _from, state) do
    to = other(from_side)
    state = deliver(state, to, state.buf[to] <> bytes)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:recv, side}, from, state) do
    case {state.buf[side], state.closed} do
      {<<>>, true} ->
        # drained and closed → report closed
        {:reply, {:error, :closed}, state}

      {<<>>, false} ->
        # nothing buffered yet — park the reader until bytes arrive (or close)
        {:noreply, put_in(state.waiting[side], from)}

      {bytes, _} ->
        # deliver buffered bytes first (even if closed — drain before reporting closed)
        {:reply, {:ok, bytes}, put_in(state.buf[side], <<>>)}
    end
  end

  # Graceful close: set the flag; wake any parked readers that have no buffered
  # bytes with {:error, :closed}. Readers WITH buffered bytes get them via the
  # normal path on their next recv (drain-before-close). The process stays alive
  # so the peer can still drain; it stops once both sides have drained+seen closed.
  def handle_call(:close, _from, state) do
    state = %{state | closed: true}

    Enum.each([:a, :b], fn side ->
      with from when from != nil <- state.waiting[side],
           <<>> <- state.buf[side] do
        GenServer.reply(from, {:error, :closed})
      else
        _ -> :ok
      end
    end)

    state = %{state | waiting: %{a: nil, b: nil}}

    # If nothing left to drain, stop; else stay to let the peer read remaining bytes.
    if state.buf.a == <<>> and state.buf.b == <<>> do
      {:stop, :normal, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  # Append bytes destined for `side`; if a reader is parked, hand off immediately.
  defp deliver(state, side, bytes) do
    case state.waiting[side] do
      nil ->
        put_in(state.buf[side], bytes)

      from ->
        GenServer.reply(from, {:ok, bytes})

        state
        |> put_in([:buf, side], <<>>)
        |> put_in([:waiting, side], nil)
    end
  end

  defp other(:a), do: :b
  defp other(:b), do: :a
end
