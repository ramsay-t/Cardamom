defmodule Cardamom.Protocol.ChainSync.Codec do
  @moduledoc """
  CBOR codec for the ChainSync mini-protocol. Grammar: `chain-sync.cddl`
  (ouroboros-network). Each message is a CBOR array with a leading integer tag:

      msgRequestNext       = [0]
      msgAwaitReply        = [1]
      msgRollForward       = [2, header, tip]
      msgRollBackward      = [3, point, tip]
      msgFindIntersect     = [4, points]
      msgIntersectFound    = [5, point, tip]
      msgIntersectNotFound = [6, tip]
      msgDone              = [7]

  For milestone 1 (observe + log) the `header`, `point`, and `tip` payloads are
  kept OPAQUE — we round-trip them as decoded-CBOR terms and do NOT decode header
  internals yet (that's the Conway header structure, deferred). Strict decode:
  unknown tags are errors; never raises.

  Internal representation:
      :request_next | :await_reply | :done
      {:roll_forward, header, tip}
      {:roll_backward, point, tip}
      {:find_intersect, points}
      {:intersect_found, point, tip}
      {:intersect_not_found, tip}
  """

  @type point :: term()
  @type tip :: term()
  @type header :: term()
  @type message ::
          :request_next
          | :await_reply
          | :done
          | {:roll_forward, header(), tip()}
          | {:roll_backward, point(), tip()}
          | {:find_intersect, [point()]}
          | {:intersect_found, point(), tip()}
          | {:intersect_not_found, tip()}

  # ---- encode ----

  @spec encode(message()) :: binary()
  def encode(:request_next), do: CBOR.encode([0])
  def encode(:await_reply), do: CBOR.encode([1])
  def encode({:roll_forward, header, tip}), do: CBOR.encode([2, header, tip])
  def encode({:roll_backward, point, tip}), do: CBOR.encode([3, point, tip])
  def encode({:find_intersect, points}), do: CBOR.encode([4, Enum.map(points, &wire_point/1)])
  def encode({:intersect_found, point, tip}), do: CBOR.encode([5, point, tip])
  def encode({:intersect_not_found, tip}), do: CBOR.encode([6, tip])
  def encode(:done), do: CBOR.encode([7])

  # A chain-sync point on the wire is [slot, #bytes(hash)] (or [] for origin). A raw
  # Elixir binary hash would CBOR-encode as a TEXT string, which the relay rejects
  # (it closed the connection on our first resume attempt) — the hash must be a CBOR
  # BYTE string. Wrap it; leave already-wrapped or origin points untouched.
  defp wire_point([slot, hash]) when is_integer(slot) and is_binary(hash),
    do: [slot, %CBOR.Tag{tag: :bytes, value: hash}]

  defp wire_point(other), do: other

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

  defp from_term([0]), do: {:ok, :request_next}
  defp from_term([1]), do: {:ok, :await_reply}
  defp from_term([2, header, tip]), do: {:ok, {:roll_forward, header, tip}}
  defp from_term([3, point, tip]), do: {:ok, {:roll_backward, point, tip}}
  defp from_term([4, points]) when is_list(points), do: {:ok, {:find_intersect, points}}
  defp from_term([5, point, tip]), do: {:ok, {:intersect_found, point, tip}}
  defp from_term([6, tip]), do: {:ok, {:intersect_not_found, tip}}
  defp from_term([7]), do: {:ok, :done}
  defp from_term(other), do: {:error, {:unknown_message, other}}
end
