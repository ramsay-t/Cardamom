defmodule Cardamom.Node do
  @moduledoc """
  The node entry point. `start/1` resolves config (defaults ← JSON file ← opts),
  opens a real TCP connection to the first peer, and starts a `Peer.Session` that
  runs the full handshake → chain-sync → keep-alive sequence.

  This is the "same code, different params" seam: the integration tests call
  `start/1` with localhost params against a SimPeer; pointing at Preview is the
  identical call with the default (or config-file) params. Nothing else changes —
  the only difference between a test run and a real run is the resolved config.

  `db` is resolved and carried but currently INERT (reserved for persistence).

  Opts (all optional; see `Cardamom.Config`):
    * `:config_file` — path to a JSON config file
    * `:first_peer`  — `%{host:, port:}` (overrides file/defaults)
    * `:network`     — network magic (mainnet refused)
    * `:db`          — db path (inert for now)
    * `:peer`        — a label for the connection (defaults to the host)
  """

  require Logger

  alias Cardamom.{Channel, Config, Peer.Session}

  @doc """
  Connect + start a session via `Session.start_link` (the session is linked to the
  caller). Used by scripts/tests that own the session's lifetime directly.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []), do: connect(opts, &Session.start_link/1)

  @doc """
  Connect + start a session UNDER `Cardamom.PeerSupervisor`, so the running node shuts it
  down GRACEFULLY (its terminate/2 sends MsgDone) on app stop. Used by the boot Connector.
  """
  @spec start_supervised(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_supervised(opts \\ []),
    do: connect(opts, &Cardamom.PeerSupervisor.start_session/1)

  # Resolve config, run the politeness gate, open the TCP channel, build session opts, then
  # hand off to `start_fun` (start_link or start a supervised child) with those opts.
  defp connect(opts, start_fun) do
    with {:ok, cfg} <- Config.resolve(opts) do
      %{host: host, port: port} = cfg.first_peer
      label = Keyword.get(opts, :peer, host)

      case connect_gate(host, port) do
        {:wait, ms} ->
          Logger.info("connect to #{host}:#{port} deferred by policy (wait #{ms}ms)")
          {:error, {:backoff, ms}}

        :ok ->
          Logger.info("connecting to #{host}:#{port} (network magic #{cfg.network}, db=#{inspect(cfg.db)})")

          case Channel.Tcp.connect(host, port) do
            {:ok, channel} ->
              report(:report_connected, host, port)

              session_opts =
                [
                  channel: channel,
                  peer: label,
                  magic: cfg.network,
                  protocols: cfg.protocols,
                  handshake: cfg.handshake
                ]
                |> maybe_put(:protocols, Keyword.get(opts, :protocols))

              start_fun.(session_opts)

            {:error, reason} ->
              report(:report_failed, host, port)
              {:error, {:connect_failed, host, port, reason}}
          end
      end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp connect_gate(host, port) do
    if Process.whereis(Cardamom.Control), do: Cardamom.Control.request_connect(host, port), else: :ok
  end

  defp report(fun, host, port) do
    if Process.whereis(Cardamom.Control), do: apply(Cardamom.Control, fun, [host, port])
    :ok
  end
end
