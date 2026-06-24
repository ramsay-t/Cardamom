defmodule Cardamom.Ledger.Shelley.Header do
  @moduledoc """
  Decoder for the **TPraos** block header — the Shelley-family eras 1 Shelley, 2 Allegra,
  3 Mary, 4 Alonzo, as sent over node-to-node chain-sync.

  SOURCE OF TRUTH: the `ToCBOR/FromCBOR (BHBody crypto)` instance in
  `cardano-protocol-tpraos/.../Cardano/Protocol/TPraos/BHeader.hs` (encodes
  `encodeListLen (9 + listLen oc + listLen pv)` = a FLAT array), and `OCert`/`ProtVer`'s
  CBORGroup instances which INLINE their fields. Verified against the real Preview era-4
  fixture `test/fixtures/preview_rollforward.hex`.

  TPraos differs from Praos (eras 5+; see `Cardamom.Ledger.Praos.Header`): it carries TWO
  CertifiedVRF fields (`bheaderEta` nonce-VRF + `bheaderL` leader-value-VRF — combined into one
  in Praos), and inlines OCert (4 fields) + ProtVer (2 fields) flat rather than nesting them.
  So `header = [header_body, kes_signature]` and `header_body` is a FLAT 15-element array:

      header_body = [
        0  block_no        : uint
        1  slot            : uint
        2  prev_hash       : bytes32 / nil
        3  issuer_vkey     : bytes32
        4  vrf_vkey        : bytes32
        5  vrf_result      : [bytes, bytes]   (eta — nonce CertifiedVRF)
        6  vrf_result_2    : [bytes, bytes]   (leader-value CertifiedVRF; TPraos-only)
        7  block_body_size : uint
        8  block_body_hash : bytes32
        9  opcert_hot_vkey : bytes32  \\
        10 opcert_n        : uint      |  OCert, flattened (CBORGroup)
        11 opcert_kes_per  : uint      |
        12 opcert_sigma    : bytes64  /
        13 protocol_major  : uint   \\  ProtVer, flattened
        14 protocol_minor  : uint   /
      ]

  Strict: a header that doesn't match this exact shape is an error, not coerced. The hash is
  the REAL blake2b-256 of the raw header bytes. Normalises to `%Cardamom.Ledger.Conway.Header{}`
  (the shared, store-compatible struct).
  """

  alias Cardamom.Crypto
  alias Cardamom.Ledger.Conway.Header, as: Normalised
  import Cardamom.Ledger.HeaderCBOR

  @doc """
  Decode RAW TPraos header bytes (after the `[era, #6.24(bytes)]` envelope is stripped) into a
  normalised `%Cardamom.Ledger.Conway.Header{}`. `{:ok, h} | {:error, reason}`. Never raises.
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

  defp as_header_shape([header_body, body_sig]), do: {:ok, header_body, body_sig}
  defp as_header_shape(other), do: {:error, {:not_a_header, other}}

  # header_body is the FLAT 15-element TPraos array (OCert and ProtVer inlined, two VRFs).
  defp decode_body([
         block_number,
         slot,
         prev_hash,
         issuer_vkey,
         vrf_vkey,
         vrf_result,
         vrf_result_2,
         block_body_size,
         block_body_hash,
         oc_hot_vkey,
         oc_n,
         oc_kes_period,
         oc_sigma,
         proto_major,
         proto_minor
       ])
       when is_integer(block_number) and is_integer(slot) and is_integer(block_body_size) and
              is_integer(oc_n) and is_integer(oc_kes_period) and
              is_integer(proto_major) and is_integer(proto_minor) do
    {:ok,
     %{
       block_number: block_number,
       slot: slot,
       prev_hash: prev_hash(prev_hash),
       issuer_vkey: bytes(issuer_vkey),
       vrf_vkey: bytes(vrf_vkey),
       vrf_result: vrf_result,
       vrf_result_2: vrf_result_2,
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

  defp decode_body(other), do: {:error, {:bad_tpraos_header_body, other}}

  defp check_kes_sig(sig) do
    case bytes(sig) do
      b when is_binary(b) -> :ok
      _ -> {:error, :bad_kes_signature}
    end
  end
end
