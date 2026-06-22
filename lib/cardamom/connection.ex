defmodule Cardamom.Connection do
  @moduledoc """
  The BEARER (mux) for one peer connection. It owns the `Cardamom.Channel` (the
  socket) and does exactly two things:

    * **inbound:** read bytes, deframe SDUs, and ROUTE each one to the process
      registered for its mini-protocol number (`send(pid, {:sdu, proto, payload})`);
    * **outbound:** accept framed writes from those protocol processes
      (`send_frame/3`) and write them to the socket — it is the SINGLE WRITER, so
      concurrent protocol processes never interleave SDUs on the wire.

  It holds NO protocol logic. Each mini-protocol (chain-sync = 2, keep-alive = 8,
  later block-fetch = 3, tx-submission = 4) is its OWN process holding this bearer's
  pid — initiator-driven ones decide when to send and feed the bearer; the bearer
  just multiplexes. This mirrors both the Haskell (mux is a dumb multiplexer over
  independent mini-protocol state machines) and the CSP (each protocol a process,
  the bearer the shared channel, the mux the hiding).

  The channel is injected (`:channel`) — `Channel.Tcp` for a relay, `Channel.Test`
  loopback for sim. Everything above the socket is identical either way.

  `terminate/2` is the backstop: it releases the socket. Protocol processes own
  their own polite `MsgDone` (sent via `send_frame/3`) and, being children ordered
  before the bearer in the session supervisor, shut down first — so their goodbyes
  reach the wire before the bearer closes it.
  """

  use GenServer
  require Logger

  alias Cardamom.{Channel, Mux.Frame}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc """
  Register the calling process as the handler for mini-protocol `proto`. Inbound
  SDUs for `proto` are delivered to it as `{:sdu, proto, payload}`. Idempotent;
  last registration wins.
  """
  def register(conn, proto) when is_integer(proto),
    do: GenServer.call(conn, {:register, proto, self()})

  @doc """
  Write a framed message for mini-protocol `proto` to the socket. The bearer is the
  sole writer, so protocol processes call this instead of touching the socket — no
  interleaved-SDU race. Cast (fire-and-forget; ordering per-caller is preserved).
  """
  def send_frame(conn, proto, bytes) when is_integer(proto) and is_binary(bytes),
    do: GenServer.cast(conn, {:send_frame, proto, bytes})

  @doc """
  Like `send_frame/3` but SYNCHRONOUS — returns only once the bytes have been
  written to the socket. Protocol clients use this for their polite `MsgDone` in
  terminate/2: a cast would be queued behind the link-death EXIT signal that closes
  the bearer, so the goodbye could lose the race with the socket close. A call is
  processed in order, guaranteeing the goodbye reaches the wire first.
  """
  def send_frame_sync(conn, proto, bytes) when is_integer(proto) and is_binary(bytes),
    do: GenServer.call(conn, {:send_frame, proto, bytes})

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)
    peer = Keyword.get(opts, :peer, "loopback")

    # Trap exits so terminate/2 runs on shutdown / link-death paths — that's where
    # we release the socket.
    Process.flag(:trap_exit, true)

    :telemetry.execute([:cardamom, :peer, :connected], %{}, %{peer: peer})
    Logger.info("connected peer=#{peer}")

    if Process.whereis(Cardamom.Peers) do
      Cardamom.Peers.register(self(), %{
        address: peer,
        direction: Keyword.get(opts, :direction, :outbound),
        version: Keyword.get(opts, :version)
      })
    end

    # The blocking recv lives in a dedicated reader process (no poll, no timeout):
    # it forwards {:bytes, _} to us and {:channel_closed, _} on close. We are then a
    # pure, never-blocking message loop — register / send_frame / inbound bytes are
    # all just mailbox messages, handled in order. Linked, so we share the reader's
    # fate (and trap_exit lets us treat its exit as a message, not a kill).
    {:ok, _reader} = Cardamom.Connection.Reader.start_link(self(), channel)

    state = %{channel: channel, peer: peer, buffer: <<>>, routes: %{}}
    {:ok, state}
  end

  @impl true
  def handle_call({:register, proto, pid}, _from, state) do
    {:reply, :ok, %{state | routes: Map.put(state.routes, proto, pid)}}
  end

  def handle_call({:send_frame, proto, bytes}, _from, state) do
    safe_send(state, proto, bytes)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:send_frame, proto, bytes}, state) do
    safe_send(state, proto, bytes)
    {:noreply, state}
  end

  # Best-effort write. The channel may already be closing during teardown (a
  # protocol process can cast a final frame at a bearer whose socket is gone); a
  # write failure there is expected, not a crash.
  defp safe_send(state, proto, bytes) do
    _ = Frame.send_msg(state.channel, proto, bytes)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Inbound bytes from the reader: append, deframe every whole SDU, route each.
  @impl true
  def handle_info({:bytes, bytes}, state) do
    {:noreply, drain(%{state | buffer: state.buffer <> bytes})}
  end

  # The reader saw the channel close — stop normally and release the socket.
  def handle_info({:channel_closed, reason}, state) do
    :telemetry.execute([:cardamom, :peer, :disconnected], %{}, %{peer: state.peer})
    Logger.info("disconnected peer=#{state.peer} reason=#{inspect(reason)}")
    {:stop, :normal, state}
  end

  # A linked protocol process exited. The bearer OUTLIVES its protocols — it does
  # NOT die just because one stopped (else a keep-alive/chain-sync teardown would
  # close the socket out from under another protocol's polite MsgDone). It stops
  # only when its CHANNEL closes or its supervisor stops it. (The reader is also
  # linked; its exit arrives as {:channel_closed, _} above before any EXIT.)
  def handle_info({:EXIT, _from, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _from, :shutdown}, state), do: {:noreply, state}
  def handle_info({:EXIT, _from, {:shutdown, _}}, state), do: {:noreply, state}

  def handle_info({:EXIT, from, reason}, state) do
    Logger.debug(fn -> "bearer: linked process #{inspect(from)} crashed: #{inspect(reason)}" end)
    {:noreply, state}
  end

  # Pull every complete SDU out of the buffer and route it.
  defp drain(state) do
    case Cardamom.Mux.SDU.decode(state.buffer) do
      {:ok, sdu, rest} ->
        state = route(sdu, %{state | buffer: rest})
        drain(state)

      {:error, _incomplete} ->
        state
    end
  end

  # Route one inbound SDU to its protocol process. The bearer does NOT interpret
  # the payload — that's the protocol process's job (Harvard boundary: inbound
  # bytes are inert data routed by number, never dispatched ON).
  defp route(%{protocol_num: proto, payload: payload}, state) do
    case Map.get(state.routes, proto) do
      pid when is_pid(pid) ->
        send(pid, {:sdu, proto, payload})

      nil ->
        Logger.debug(fn ->
          "no handler for mini-protocol #{proto}; dropping #{byte_size(payload)}B"
        end)
    end

    state
  end

  # OTP-native shutdown backstop: release the socket. Protocol processes send their
  # own MsgDone (they shut down first, being ordered before the bearer). Brutal
  # kills / BEAM death skip this entirely — fine, the OS closes the socket and the
  # relay sees a normal dropped connection.
  @impl true
  def terminate(reason, state) do
    Logger.info("bearer peer=#{state.peer}: releasing socket (reason=#{inspect(reason)})")
    graceful_close(reason, state)
    :ok
  end

  # A clean teardown closes POLITELY to avoid a RST on the wire (which a peer reads as
  # "the client choked" — Marcin 2026-06-22). By now the protocol processes have sent
  # their Dones (they're ordered before the bearer). We then:
  #   1. shutdown_write — send our FIN ("we're done writing"), keep the read side open;
  #   2. briefly let the Reader keep draining the peer's in-flight bytes (it's looping on
  #      recv) so nothing is left UNREAD when we close — close-with-unread-data is what
  #      forces the kernel to send RST instead of FIN;
  #   3. close.
  # On a channel-closed teardown (the peer already FIN'd — the {:channel_closed} path)
  # there's nothing in flight, so a plain close is already a clean FIN/FIN.
  defp graceful_close(reason, state) when reason in [:normal, :shutdown] do
    safe(fn -> Channel.shutdown_write(state.channel) end)
    # Bounded window for the Reader to drain the peer's remaining bytes + see its FIN.
    # Short — we're closing, not waiting on the peer indefinitely.
    Process.sleep(100)
    safe(fn -> Channel.close(state.channel) end)
  end

  defp graceful_close(_abnormal, state), do: safe(fn -> Channel.close(state.channel) end)

  defp safe(fun) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
