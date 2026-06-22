defmodule Cardamom.Channel do
  @moduledoc """
  The bidirectional byte channel a mini-protocol talks through — the seam that
  keeps the protocol FSMs testable without a real socket.

  This mirrors the Ouroboros `Channel` abstraction (CSP model ~131-135): the FSM
  sends/receives bytes and does not know whether the other end is a real TCP
  socket (`Cardamom.Channel.Tcp`) or a test process (`Cardamom.Channel.Test`).
  Same construction the CSP uses; same reason it's CSP-faithful AND unit-testable.

  Channels carry raw bytes. SDU framing and mini-protocol demux sit *above* this
  (the socket-owning Connection); CBOR encode/decode sits above that. A Channel is
  deliberately dumb: send these bytes, give me some bytes back.
  """

  @type t :: term()

  @doc "Send bytes to the far end."
  @callback send(t(), iodata()) :: :ok | {:error, term()}

  @doc """
  Receive up to the next chunk of bytes (blocking until some arrive, the channel
  closes, or `timeout` ms elapse). Returns `{:ok, bytes}` | `{:error, reason}`.
  """
  @callback recv(t(), timeout()) :: {:ok, binary()} | {:error, term()}

  @doc "Close the channel."
  @callback close(t()) :: :ok

  @doc """
  Half-close: send our FIN (stop writing) but keep the read side open so we can drain
  the peer's in-flight bytes and see ITS FIN. Calling `close/1` while the peer's bytes
  are still unread in our receive buffer makes the kernel emit a RST instead of a FIN
  (POSIX), which a peer reads as "the client choked". The graceful sequence is:
  send our protocol Dones → `shutdown_write/1` → drain until the peer closes → `close/1`.
  Optional: transports that can't half-close fall back to a plain close.
  """
  @callback shutdown_write(t()) :: :ok | {:error, term()}
  @optional_callbacks shutdown_write: 1

  # Convenience dispatch: a channel is `{module, ref}`.
  @spec send({module(), t()}, iodata()) :: :ok | {:error, term()}
  def send({mod, ref}, bytes), do: mod.send(ref, bytes)

  @spec recv({module(), t()}, timeout()) :: {:ok, binary()} | {:error, term()}
  def recv({mod, ref}, timeout \\ 5_000), do: mod.recv(ref, timeout)

  @spec close({module(), t()}) :: :ok
  def close({mod, ref}), do: mod.close(ref)

  # Half-close if the transport supports it; otherwise a no-op (caller then close/1s).
  @spec shutdown_write({module(), t()}) :: :ok | {:error, term()}
  def shutdown_write({mod, ref}) do
    if function_exported?(mod, :shutdown_write, 1), do: mod.shutdown_write(ref), else: :ok
  end
end
