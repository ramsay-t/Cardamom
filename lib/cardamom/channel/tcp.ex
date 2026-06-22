defmodule Cardamom.Channel.Tcp do
  @moduledoc """
  Real `Cardamom.Channel` over a TCP socket (`:gen_tcp`). The production transport
  the protocol FSMs talk through — the same behaviour as `Channel.Test`, so
  everything above the socket runs identically whether driven by a loopback fake
  or a real relay.

  Raw-bytes channel: SDU framing and CBOR sit above it. `recv/2` returns
  `{:error, :closed}` on a dropped socket (matching `Channel.Test`, so the
  Connection's disconnect handling is identical).
  """

  @behaviour Cardamom.Channel

  defstruct [:socket]

  @doc """
  Connect to `host:port`. Active-passive (`active: false`) so we drive reads via
  `recv/2`. Binary mode, no Nagle for protocol responsiveness.
  """
  @spec connect(String.t() | charlist(), :inet.port_number(), timeout()) ::
          {:ok, {__MODULE__, %__MODULE__{}}} | {:error, term()}
  def connect(host, port, timeout \\ 5_000) do
    host = to_charlist(host)

    case :gen_tcp.connect(host, port, [:binary, active: false, nodelay: true], timeout) do
      {:ok, socket} -> {:ok, {__MODULE__, %__MODULE__{socket: socket}}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Server side: open a listening socket on `port` (use 0 for an OS-assigned port).
  Returns `{:ok, listen_socket, port}`. Used by the integration test loop (and,
  later, the relay/serving listener). Pair with `accept/2`.
  """
  @spec listen(:inet.port_number()) :: {:ok, :gen_tcp.socket(), :inet.port_number()} | {:error, term()}
  def listen(port \\ 0) do
    with {:ok, lsock} <-
           :gen_tcp.listen(port, [:binary, active: false, nodelay: true, reuseaddr: true]),
         {:ok, assigned} <- :inet.port(lsock) do
      {:ok, lsock, assigned}
    end
  end

  @doc "Accept one inbound connection on `listen_socket`, wrapped as a Channel."
  @spec accept(:gen_tcp.socket(), timeout()) ::
          {:ok, {__MODULE__, %__MODULE__{}}} | {:error, term()}
  def accept(listen_socket, timeout \\ 5_000) do
    case :gen_tcp.accept(listen_socket, timeout) do
      {:ok, socket} -> {:ok, {__MODULE__, %__MODULE__{socket: socket}}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Cardamom.Channel
  def send(%__MODULE__{socket: socket}, bytes), do: :gen_tcp.send(socket, bytes)

  @impl Cardamom.Channel
  def recv(%__MODULE__{socket: socket}, timeout) do
    # 0 = read whatever bytes are available (we deframe SDUs ourselves above).
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :timeout} -> {:error, :timeout}
      {:error, :closed} -> {:error, :closed}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Cardamom.Channel
  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)
end
