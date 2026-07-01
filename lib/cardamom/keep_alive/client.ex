defmodule Cardamom.KeepAlive.Client do
  @moduledoc """
  Drives the keep-alive mini-protocol (8) as the CLIENT/initiator — periodically
  sends `MsgKeepAlive [0, cookie]` so the relay doesn't reap us.

  ## Why this exists (and why it's its own process)

  In keep-alive the client holds agency: the protocol's `StClient` timeout is **97
  seconds** (`ouroboros-network/.../Protocol/KeepAlive/Codec.hs:105`). If we go that
  long without sending a ping, the relay closes the connection — which is exactly
  what we observed on Preview (handshake → chain-sync, no pings → dropped at 97s).

  Sending pings on a timer is an **internal choice** (we decide *when*, driven by a
  hidden τ — the timer), so per our CSP-fidelity rule it lives in its own driver
  process. Like every mini-protocol it holds the BEARER (`Cardamom.Connection`) pid:
  it registers for proto 8, writes pings via `Connection.send_frame/3` (single
  writer), and receives the relay's `MsgKeepAliveResponse [1, cookie]` as
  `{:sdu, 8, payload}`.

  ## Dead-peer detection (resilience)

  Sending pings keeps the relay from reaping US, but it doesn't tell us if the RELAY (or the
  network) has gone away — e.g. a laptop sleep or wifi drop, where the socket goes silent with
  no FIN. The bearer's reader is blocked in `recv` with no timeout, so nothing notices the dead
  air. So we also TRACK responses: each ping increments an `unacked` counter; each
  `MsgKeepAliveResponse` resets it to 0. After `@max_unacked` consecutive unanswered pings the
  peer is declared dead and this driver stops with `{:shutdown, :keepalive_timeout}` — which (we
  link the bearer) tears the session down, and the supervisor's reconnect logic redials. The
  threshold (3 pings * 10s = ~30s) is well inside the relay's own 97s StClient reap, with margin
  for one-off packet loss.

  Opts:
    * `:conn`        — the bearer pid (required)
    * `:interval_ms` — ping period (default 10_000ms, matching the Haskell tests'
                       `keepAliveInterval = 10`; comfortably inside the 97s reap)
    * `:max_unacked` — consecutive unanswered pings before declaring the peer dead (default 3)
  """

  use GenServer
  require Logger

  @keep_alive 8
  # 10s: well inside the 97s StClient timeout (~9 pings of margin), and the value
  # the ouroboros-network keep-alive tests use.
  @default_interval_ms 10_000
  # keep-alive cookie is a word16 on the wire; wrap at 2^16.
  @cookie_mod 0x10000
  # 3 unanswered pings (~30s) → peer dead. Inside the 97s reap, tolerant of one lost packet.
  @default_max_unacked 3

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    max_unacked = Keyword.get(opts, :max_unacked, @default_max_unacked)

    # Reflect the bearer's fate: if it dies, this driver has nothing to feed.
    Process.link(conn)
    Process.flag(:trap_exit, true)

    :ok = Cardamom.Connection.register(conn, @keep_alive)

    schedule(interval)
    {:ok, %{conn: conn, interval: interval, cookie: 0, unacked: 0, max_unacked: max_unacked}}
  end

  @impl true
  def handle_info(:ping, %{unacked: unacked, max_unacked: max} = state) when unacked >= max do
    # We've sent `max` pings since the last response — the relay (or the network) is gone.
    # Stop so the linked bearer comes down and the session reconnects. {:shutdown, _} so it's a
    # clean stop, not a crash.
    Logger.warning("keep_alive peer=#{peer(state)}: #{unacked} unanswered pings (~#{unacked * div(state.interval, 1000)}s) — peer dead, dropping")
    {:stop, {:shutdown, :keepalive_timeout}, state}
  end

  def handle_info(:ping, %{conn: conn, cookie: cookie} = state) do
    # MsgKeepAlive [0, cookie] on proto 8 via the bearer (single writer). Count it as outstanding
    # until a response resets the counter.
    Cardamom.Connection.send_frame(conn, @keep_alive, CBOR.encode([0, cookie]))
    schedule(state.interval)
    {:noreply, %{state | cookie: rem(cookie + 1, @cookie_mod), unacked: state.unacked + 1}}
  end

  # Inbound keep-alive SDU. [1, cookie] = the relay's response to our ping (alive confirmation) →
  # the peer is alive, reset the unacked counter. [0, cookie] = the peer pinging us — echo it back
  # (and it counts as evidence the peer is alive too, so reset).
  def handle_info({:sdu, @keep_alive, payload}, %{conn: conn} = state) do
    state =
      case CBOR.decode(payload) do
        {:ok, [0, cookie], _} when is_integer(cookie) ->
          Cardamom.Connection.send_frame(conn, @keep_alive, CBOR.encode([1, cookie]))
          %{state | unacked: 0}

        {:ok, [1, _cookie], _} ->
          # Response to one of our pings — peer is alive.
          %{state | unacked: 0}

        _ ->
          state
      end

    {:noreply, state}
  end

  # The bearer (which we link to) exited — stop with the same reason.
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  defp schedule(interval), do: Process.send_after(self(), :ping, interval)

  defp peer(%{conn: conn}), do: inspect(conn)
end
