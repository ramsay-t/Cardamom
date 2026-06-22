defmodule Cardamom.Connection.Reader do
  @moduledoc """
  The blocking-recv half of the bearer, isolated in its own process.

  A bearer (`Cardamom.Connection`) is a single process that must both READ the
  socket and SERVE control messages (register / send_frame). One process can't sit
  in a blocking `recv` AND answer messages — the old design "solved" that by polling
  recv on a 100ms timer, which is time-division concurrency (a poll) on a runtime
  that gives us real processes. Worse, it raced: while parked in recv, a queued
  `register` could be processed AFTER an inbound SDU was already routed → dropped.

  So we split it the CSP way: this process does nothing but the blocking receive —

      loop:  {:ok, bytes} = Channel.recv(chan)   # blocks, NO timeout
             send(bearer, {:bytes, bytes})

  and the bearer becomes a pure, never-blocking message loop. Blocking here is fine:
  this process has no other duty to starve. On channel close/error it tells the
  bearer once and exits; linked to the bearer so they share fate.
  """

  alias Cardamom.Channel

  @doc "Start a reader linked to `bearer`, reading `channel` and forwarding bytes to it."
  def start_link(bearer, channel) do
    {:ok, spawn_link(fn -> loop(bearer, channel) end)}
  end

  defp loop(bearer, channel) do
    # No timeout: park until bytes arrive or the channel closes. (Channel.recv takes
    # a timeout arg; :infinity means a pure blocking receive — no poll.)
    case Channel.recv(channel, :infinity) do
      {:ok, bytes} ->
        send(bearer, {:bytes, bytes})
        loop(bearer, channel)

      {:error, reason} ->
        # Channel gone — report once; the bearer will stop and release the socket.
        send(bearer, {:channel_closed, reason})
        :ok
    end
  end
end
