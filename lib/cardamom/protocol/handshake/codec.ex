defmodule Cardamom.Protocol.Handshake.Codec do
  @moduledoc """
  CBOR codec for the NodeToNode Handshake mini-protocol (v14+).

  Grammar: `handshake-node-to-node-v14.cddl` (in ouroboros-network). Messages are
  CBOR arrays with a leading integer tag:

      msgProposeVersions = [0, versionTable]   ; versionTable: definite-len map
      msgAcceptVersion   = [1, versionNumber, nodeToNodeVersionData]
      msgRefuse          = [2, refuseReason]
      msgQueryReply      = [3, versionTable]

  v14 `nodeToNodeVersionData = [networkMagic, initiatorOnlyDiffusionMode,
  peerSharing, query]`.

  Decoding is STRICT (enforce, never coerce — strict-CDDL directive): unknown
  tags and malformed shapes are errors, not best-effort interpretations. The
  `cbor` lib encodes definite-length maps by default, satisfying the CDDL's
  "codec only accepts definite-length maps" note.

  Internal representation (Elixir-native, decoupled from the wire):

      {:propose_versions, %{version => version_data}}
      {:accept_version, version, version_data}
      {:refuse, refuse_reason}
      {:query_reply, %{version => version_data}}

  where `version_data = %{network_magic:, initiator_only:, peer_sharing:, query:}`
  and `refuse_reason` is one of:
      {:version_mismatch, [version]}
      {:handshake_decode_error, version, String.t()}
      {:refused, version, String.t()}
  """

  @type version :: non_neg_integer()
  @type version_data :: %{
          network_magic: non_neg_integer(),
          initiator_only: boolean(),
          peer_sharing: 0..1,
          query: boolean()
        }
  @type refuse_reason ::
          {:version_mismatch, [version()]}
          | {:handshake_decode_error, version(), String.t()}
          | {:refused, version(), String.t()}
  @type message ::
          {:propose_versions, %{version() => version_data()}}
          | {:accept_version, version(), version_data()}
          | {:refuse, refuse_reason()}
          | {:query_reply, %{version() => version_data()}}

  # ---- encode ----

  @spec encode(message()) :: binary()
  def encode({:propose_versions, table}),
    do: CBOR.encode([0, encode_table(table)])

  def encode({:accept_version, version, vd}),
    do: CBOR.encode([1, version, encode_vd(vd)])

  def encode({:refuse, reason}),
    do: CBOR.encode([2, encode_refuse(reason)])

  def encode({:query_reply, table}),
    do: CBOR.encode([3, encode_table(table)])

  defp encode_table(table) when is_map(table),
    do: Map.new(table, fn {v, vd} -> {v, encode_vd(vd)} end)

  defp encode_vd(%{
         network_magic: m,
         initiator_only: io,
         peer_sharing: ps,
         query: q
       }),
       do: [m, io, ps, q]

  defp encode_refuse({:version_mismatch, versions}), do: [0, versions]
  defp encode_refuse({:handshake_decode_error, v, msg}), do: [1, v, msg]
  defp encode_refuse({:refused, v, msg}), do: [2, v, msg]

  # ---- decode (strict; never raises) ----

  @spec decode(binary()) :: {:ok, message(), binary()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    case CBOR.decode(bytes) do
      {:ok, term, rest} -> with {:ok, msg} <- from_term(term), do: {:ok, msg, rest}
      {:error, e} -> {:error, {:cbor, e}}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  defp from_term([0, table]), do: with({:ok, t} <- decode_table(table), do: {:ok, {:propose_versions, t}})
  defp from_term([1, v, vd]) when is_integer(v), do: with({:ok, d} <- decode_vd(vd), do: {:ok, {:accept_version, v, d}})
  defp from_term([2, reason]), do: with({:ok, r} <- decode_refuse(reason), do: {:ok, {:refuse, r}})
  defp from_term([3, table]), do: with({:ok, t} <- decode_table(table), do: {:ok, {:query_reply, t}})
  defp from_term(other), do: {:error, {:unknown_message, other}}

  defp decode_table(table) when is_map(table) do
    Enum.reduce_while(table, {:ok, %{}}, fn {v, vd}, {:ok, acc} ->
      case decode_vd(vd) do
        {:ok, d} when is_integer(v) -> {:cont, {:ok, Map.put(acc, v, d)}}
        {:ok, _} -> {:halt, {:error, {:bad_version_key, v}}}
        err -> {:halt, err}
      end
    end)
  end

  defp decode_table(other), do: {:error, {:bad_version_table, other}}

  defp decode_vd([m, io, ps, q])
       when is_integer(m) and is_boolean(io) and ps in 0..1 and is_boolean(q),
       do: {:ok, %{network_magic: m, initiator_only: io, peer_sharing: ps, query: q}}

  defp decode_vd(other), do: {:error, {:bad_version_data, other}}

  defp decode_refuse([0, versions]) when is_list(versions), do: {:ok, {:version_mismatch, versions}}
  defp decode_refuse([1, v, msg]) when is_integer(v), do: {:ok, {:handshake_decode_error, v, to_str(msg)}}
  defp decode_refuse([2, v, msg]) when is_integer(v), do: {:ok, {:refused, v, to_str(msg)}}
  defp decode_refuse(other), do: {:error, {:bad_refuse_reason, other}}

  # CBOR text strings decode to %CBOR.Tag{} or binary depending on lib version;
  # normalise to a plain string.
  defp to_str(%CBOR.Tag{value: v}) when is_binary(v), do: v
  defp to_str(s) when is_binary(s), do: s
  defp to_str(other), do: inspect(other)
end
