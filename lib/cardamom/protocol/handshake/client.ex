defmodule Cardamom.Protocol.Handshake.Client do
  @moduledoc """
  NodeToNode Handshake client (initiator). The first mini-protocol on any
  connection: propose the versions we speak, receive the peer's choice (or a
  refusal). Must succeed before any other protocol runs.

  Per the CSP/agency structure this is a tiny state machine: at the start WE hold
  agency (we propose — an internal choice of what to offer, here driven by the
  caller's `versions`/`magic` options, i.e. a "driver" input); then the PEER holds
  agency and we receive (external choice: accept | refuse). Two states, so it's
  written as a straight-line `run/2` rather than a full `:gen_statem` — the agency
  flip is the single send→recv handoff.

  We always declare `initiator_only_diffusion_mode = true`: we only initiate, we
  do not serve. That is our observer role expressed on the wire.
  """

  alias Cardamom.Mux.Frame
  alias Cardamom.Protocol.Handshake.Codec

  @handshake_protocol 0

  @type agreed :: %{version: non_neg_integer(), version_data: Codec.version_data()}

  @doc """
  Run the handshake to completion over `channel`.

  Options: `:magic` (network magic, required), `:versions` (list to propose,
  default [14]). Returns `{:ok, agreed}` or `{:error, reason}`.
  """
  @spec run(Cardamom.Channel.t(), keyword()) :: {:ok, agreed()} | {:error, term()}
  def run(channel, opts) do
    magic = Keyword.fetch!(opts, :magic)
    versions = Keyword.get(opts, :versions, [14])

    table =
      Map.new(versions, fn v -> {v, version_data(magic)} end)

    # WE have agency: propose. (Send is the last act before we flip to receiving.)
    with :ok <- Frame.send_msg(channel, @handshake_protocol, Codec.encode({:propose_versions, table})),
         # PEER has agency: external choice accept | refuse.
         {:ok, payload, _sdu, _rest} <- Frame.recv_msg(channel),
         {:ok, reply, _} <- Codec.decode(payload) do
      interpret(reply)
    end
  end

  defp interpret({:accept_version, version, version_data}) do
    :telemetry.execute(
      [:cardamom, :peer, :connected],
      %{},
      %{protocol: "handshake", version: version}
    )

    {:ok, %{version: version, version_data: version_data}}
  end

  defp interpret({:refuse, reason}), do: {:error, {:refused, reason}}
  defp interpret(other), do: {:error, {:unexpected_handshake_reply, other}}

  # v14 nodeToNodeVersionData. initiator_only = true (observer); peer_sharing off;
  # query false (we're connecting to talk, not to query versions).
  defp version_data(magic) do
    %{network_magic: magic, initiator_only: true, peer_sharing: 0, query: false}
  end
end
