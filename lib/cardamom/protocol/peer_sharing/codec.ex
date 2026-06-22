defmodule Cardamom.Protocol.PeerSharing.Codec do
  @moduledoc """
  PeerSharing mini-protocol (10) codec. Grammar from the authoritative CDDL
  (ouroboros-network .../cddl/specs/peer-sharing-v14.cddl):

      msgShareRequest = [0, word8]            # initiator asks for up to N peers
      msgSharePeers   = [1, peerAddresses]    # responder replies with addresses
      msgDone         = [2]
      peerAddresses = [* peerAddress]
      peerAddress = [0, word32, port]                         ; IPv4 + port
                  / [1, word32, word32, word32, word32, port] ; IPv6 + port
      port = word16

  A peerAddress carries the IP as packed integer(s), NOT a string. We decode to
  `%{host: dotted_or_colon_string, port: integer}` and encode back. Strict: decode
  never raises (Harvard boundary — these are untrusted addresses, inert data we record,
  never dial).
  """

  @type peer :: %{host: String.t(), port: non_neg_integer()}
  @type message ::
          {:share_request, non_neg_integer()}
          | {:share_peers, [peer()]}
          | :done

  # ---- encode ----

  @spec encode(message()) :: binary()
  def encode({:share_request, amount}) when is_integer(amount),
    do: CBOR.encode([0, amount])

  # PeerSharing's wire format carries IP ADDRESSES only (packed word32) — there is no
  # field for a DNS hostname. So we encode only peers whose host is a numeric IP; a
  # hostname-only peer is silently skipped (it can't be represented in this protocol).
  def encode({:share_peers, peers}) when is_list(peers),
    do: CBOR.encode([1, peers |> Enum.map(&encode_addr/1) |> Enum.reject(&is_nil/1)])

  def encode(:done), do: CBOR.encode([2])

  defp encode_addr(%{host: host, port: port}) do
    case parse_ip(host) do
      {:v4, w32} -> [0, w32, port]
      {:v6, a, b, c, d} -> [1, a, b, c, d, port]
      :not_ip -> nil
    end
  end

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

  defp from_term([0, amount]) when is_integer(amount), do: {:ok, {:share_request, amount}}
  defp from_term([2]), do: {:ok, :done}

  defp from_term([1, addrs]) when is_list(addrs) do
    {:ok, {:share_peers, Enum.map(addrs, &decode_addr/1)}}
  end

  defp from_term(other), do: {:error, {:unknown_peer_sharing_message, other}}

  # IPv4: [0, word32, port]. IPv6: [1, w32, w32, w32, w32, port].
  defp decode_addr([0, w32, port]), do: %{host: ipv4(w32), port: port}

  defp decode_addr([1, a, b, c, d, port]),
    do: %{host: ipv6(a, b, c, d), port: port}

  # ---- IP <-> integer ----

  defp parse_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {a, b, c, d}} ->
        {:v4, Bitwise.bsl(a, 24) |> Bitwise.bor(Bitwise.bsl(b, 16)) |> Bitwise.bor(Bitwise.bsl(c, 8)) |> Bitwise.bor(d)}

      {:ok, {a, b, c, d, e, f, g, h}} ->
        # Pack the 8 16-bit groups into 4 word32s (groups 0-1, 2-3, 4-5, 6-7).
        {:v6, w32(a, b), w32(c, d), w32(e, f), w32(g, h)}

      # Not a numeric IP (e.g. a DNS hostname) — un-shareable over PeerSharing.
      {:error, _} ->
        :not_ip
    end
  end

  defp w32(hi, lo), do: Bitwise.bor(Bitwise.bsl(hi, 16), lo)

  defp ipv4(w32) do
    <<a, b, c, d>> = <<w32::unsigned-32>>
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp ipv6(a, b, c, d) do
    [a, b, c, d]
    |> Enum.flat_map(fn w -> [Bitwise.bsr(w, 16), Bitwise.band(w, 0xFFFF)] end)
    |> Enum.map_join(":", &Integer.to_string(&1, 16))
  end
end
