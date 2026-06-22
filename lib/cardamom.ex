defmodule Cardamom do
  @moduledoc """
  Top-level control API for a running Cardamom node — the functions you call from
  an `iex` prompt (locally, or over SSH; see security.md — control is local-only,
  never via exposed Erlang distribution).

  These are thin wrappers that message the registered `Cardamom.Control` process.
  """

  @doc "What the node currently knows: connected peers and count."
  defdelegate status, to: Cardamom.Control

  @doc "Gracefully disconnect all peers (polite MsgDone, no reconnect)."
  defdelegate disconnect_all, to: Cardamom.Control

  @doc "Gracefully disconnect all peers, then stop the whole node."
  defdelegate shutdown, to: Cardamom.Control
end
