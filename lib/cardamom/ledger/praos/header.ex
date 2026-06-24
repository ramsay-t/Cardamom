defmodule Cardamom.Ledger.Praos.Header do
  @moduledoc """
  Decoder for the **Praos** block header (eras 5 Babbage, 6 Conway, 7 Dijkstra) as sent over
  node-to-node chain-sync.

  SOURCE OF TRUTH: the `EncCBOR (HeaderBody crypto)` instance in
  `ouroboros-consensus-protocol/.../Ouroboros/Consensus/Protocol/Praos/Header.hs` (lines
  176-216 at time of writing). Verified field-by-field against a real Preview era-5 RollForward.

  Praos differs from the older TPraos header (Shelley..Alonzo; see
  `Cardamom.Ledger.Shelley.Header`) in three ways, which is why the old 15-field decoder
  rejected every live header:

    * ONE combined CertifiedVRF (`hbVrfRes`) instead of TWO (`bheaderEta` + `bheaderL`).
    * OCert is a NESTED 4-element array (its own EncCBOR via CBORGroup), not 4 inlined fields.
    * ProtVer is a NESTED 2-element array, not 2 inlined fields.

  So `header = [header_body, kes_signature]` and `header_body` is a 10-element array:

      header_body = [
        0  block_no        : uint
        1  slot            : uint
        2  prev_hash       : bytes32 / nil      (nil at genesis / era start)
        3  issuer_vkey     : bytes32
        4  vrf_vkey        : bytes32
        5  vrf_result      : [bytes, bytes]     (ONE CertifiedVRF: output, proof)
        6  block_body_size : uint
        7  block_body_hash : bytes32
        8  operational_cert: [bytes32, uint, uint, bytes64]   (nested OCert)
        9  protocol_version: [uint, uint]                       (nested ProtVer)
      ]

  Strict: a header that doesn't match this exact shape is an error, not coerced. The hash is
  the REAL blake2b-256 of the raw header bytes (Praos memoises its own original bytes — the
  `#6.24` payload we were handed — so hashing `raw` is correct; NEVER re-encode).

  Normalises to `%Cardamom.Ledger.Conway.Header{}` (the shared, store-compatible struct), with
  `vrf_result_2: nil` since Praos has a single VRF.
  """

  alias Cardamom.Crypto
  alias Cardamom.Ledger.Conway.Header, as: Normalised
  import Cardamom.Ledger.HeaderCBOR

  @doc """
  Decode RAW Praos header bytes (after the chain-sync envelope `[era, #6.24(bytes)]` has been
  stripped) into a normalised `%Cardamom.Ledger.Conway.Header{}`. `{:ok, h} | {:error, reason}`.
  Never raises.
  """
  @spec decode(binary()) :: {:ok, Normalised.t()} | {:error, term()}
  def decode(raw) when is_binary(raw) do
    with {:ok, term, _rest} <- cbor_decode(raw),
         {:ok, header_body, body_sig} <- as_header_shape(term),
         {:ok, body} <- decode_body(header_body),
         :ok <- check_kes_sig(body_sig) do
      hash = Crypto.blake2b_256(raw)

      {:ok,
       struct(Normalised, Map.merge(body, %{hash: hash, hash_hex: hex(hash), raw_size: byte_size(raw)}))}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  def decode(_), do: {:error, :not_binary}

  # header is a 2-element array [header_body, body_signature].
  defp as_header_shape([header_body, body_sig]), do: {:ok, header_body, body_sig}
  defp as_header_shape(other), do: {:error, {:not_a_header, other}}

  # header_body is the NESTED 10-element Praos array.
  defp decode_body([
         block_number,
         slot,
         prev_hash,
         issuer_vkey,
         vrf_vkey,
         vrf_result,
         block_body_size,
         block_body_hash,
         [oc_hot_vkey, oc_n, oc_kes_period, oc_sigma],
         [proto_major, proto_minor]
       ])
       when is_integer(block_number) and is_integer(slot) and is_integer(block_body_size) and
              is_integer(oc_n) and is_integer(oc_kes_period) and
              is_integer(proto_major) and is_integer(proto_minor) and
              is_list(vrf_result) do
    {:ok,
     %{
       block_number: block_number,
       slot: slot,
       prev_hash: prev_hash(prev_hash),
       issuer_vkey: bytes(issuer_vkey),
       vrf_vkey: bytes(vrf_vkey),
       vrf_result: vrf_result,
       vrf_result_2: nil,
       block_body_size: block_body_size,
       block_body_hash: bytes(block_body_hash),
       operational_cert: %{
         hot_vkey: bytes(oc_hot_vkey),
         sequence_number: oc_n,
         kes_period: oc_kes_period,
         sigma: bytes(oc_sigma)
       },
       protocol_version: {proto_major, proto_minor}
     }}
  end

  defp decode_body(other), do: {:error, {:bad_praos_header_body, other}}

  # KES signature is bytes .size 448; sanity-check present + binary.
  defp check_kes_sig(sig) do
    case bytes(sig) do
      b when is_binary(b) -> :ok
      _ -> {:error, :bad_kes_signature}
    end
  end
end
