defmodule Cardamom.Ledger.Conway.Header do
  @moduledoc """
  Decoder for the Praos block header as sent over node-to-node chain-sync.

  SOURCE OF TRUTH: `ouroboros-consensus-protocol/.../Praos/Header.hs` (the
  `HeaderBody` `EncCBOR`/`DecCBOR`), VERIFIED against real captured Preview bytes
  (test/fixtures/preview_rollforward.hex, era 4, 961-byte header). NOTE: this is
  the CONSENSUS Praos header, not the ledger CDDL's block header — and the
  `OCert` and `ProtVer` are encoded as flat `CBORGroup`s (spliced inline), so the
  `header_body` is a FLAT 15-element array, not the 10 nested fields the ledger
  CDDL reads suggest. (That "10 vs 15" was CBORGroup inlining + reading the wrong
  layer — see CLAUDE_NOTES.)

  Verified field layout (header = [header_body, kes_signature(448)]):

      header_body = [
        0  block_no        : uint
        1  slot            : uint
        2  prev_hash       : bytes32 / nil      (nil at genesis / era start)
        3  issuer_vkey     : bytes32
        4  vrf_vkey        : bytes32
        5  vrf_result      : [bytes64, bytes80]   (CertifiedVRF)
        6  vrf_result_2    : [bytes64, bytes80]   (2nd VRF cert; pre-combined-VRF)
        7  block_body_size : uint
        8  block_body_hash : bytes32
        9  opcert_hot_vkey : bytes32  \\
        10 opcert_n        : uint      |  OCert, flattened (CBORGroup)
        11 opcert_kes_per  : uint      |
        12 opcert_sigma    : bytes64  /
        13 protocol_major  : uint   \\  ProtVer, flattened
        14 protocol_minor  : uint   /
      ]

  Strict: a header that doesn't match this exact shape is an error, not coerced.
  The hash is the REAL blake2b-256 of the raw header bytes.
  """

  alias Cardamom.Crypto

  @type t :: %__MODULE__{
          hash: <<_::256>>,
          hash_hex: String.t(),
          block_number: non_neg_integer(),
          slot: non_neg_integer(),
          prev_hash: <<_::256>> | nil,
          issuer_vkey: binary(),
          vrf_vkey: binary(),
          vrf_result: term(),
          vrf_result_2: term(),
          block_body_size: non_neg_integer(),
          block_body_hash: <<_::256>>,
          operational_cert: map(),
          protocol_version: {non_neg_integer(), non_neg_integer()},
          raw_size: non_neg_integer()
        }

  defstruct [
    :hash,
    :hash_hex,
    :block_number,
    :slot,
    :prev_hash,
    :issuer_vkey,
    :vrf_vkey,
    :vrf_result,
    :vrf_result_2,
    :block_body_size,
    :block_body_hash,
    :operational_cert,
    :protocol_version,
    :raw_size
  ]

  @doc """
  Decode RAW header bytes (after the chain-sync transport envelope
  `[era, #6.24(bytes)]` has been stripped) into a fully-decoded `%Header{}`,
  including its real blake2b-256 hash. `{:ok, header}` | `{:error, reason}`.
  Never raises.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(raw) when is_binary(raw) do
    with {:ok, term, _rest} <- cbor_decode(raw),
         {:ok, header_body, body_sig} <- as_header_shape(term),
         {:ok, body} <- decode_body(header_body),
         :ok <- check_kes_sig(body_sig) do
      hash = Crypto.blake2b_256(raw)
      {:ok, struct(__MODULE__, Map.merge(body, %{hash: hash, hash_hex: hex(hash), raw_size: byte_size(raw)}))}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  def decode(_), do: {:error, :not_binary}

  # header is a 2-element array [header_body, body_signature].
  defp as_header_shape([header_body, body_sig]), do: {:ok, header_body, body_sig}
  defp as_header_shape(other), do: {:error, {:not_a_header, other}}

  # header_body is a FLAT 15-element array (OCert and ProtVer inlined).
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
       prev_hash: decode_prev_hash(prev_hash),
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

  defp decode_body(other), do: {:error, {:bad_header_body, other}}

  defp decode_prev_hash(nil), do: nil
  defp decode_prev_hash(h), do: bytes(h)

  # KES signature is bytes .size 448; sanity-check present + binary.
  defp check_kes_sig(sig) do
    case bytes(sig) do
      b when is_binary(b) -> :ok
      _ -> {:error, :bad_kes_signature}
    end
  end

  # The cbor lib decodes byte strings to %CBOR.Tag{tag: :bytes, value: ...}; unwrap.
  defp bytes(%CBOR.Tag{tag: :bytes, value: v}), do: v
  defp bytes(b) when is_binary(b), do: b
  defp bytes(other), do: other

  defp cbor_decode(raw) do
    case CBOR.decode(raw) do
      {:ok, term, rest} -> {:ok, term, rest}
      {:error, e} -> {:error, {:cbor, e}}
    end
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)
end
