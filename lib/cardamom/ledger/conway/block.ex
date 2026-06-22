defmodule Cardamom.Ledger.Conway.Block do
  @moduledoc """
  Conway block — block-LEVEL decode (M1: not into transaction internals yet).

  Wire shape (CDDL):
      block = [ header
              , transaction_bodies       : [* transaction_body]
              , transaction_witness_sets : [* transaction_witness_set]
              , auxiliary_data_set        : {* tx_index => auxiliary_data}
              , invalid_transactions      : [* tx_index] ]

  Two jobs here:

  1. **Block-level fields** for the store: the header (→ its hash = the block's
     identity), and the transaction count (`length(tx_bodies)`).

  2. **block_body_hash verification** — the security check. A header commits to its
     body via `block_body_hash`; "you can attach anything to a valid header", so a
     fetched body MUST be verified against that commitment before we trust it. The
     algorithm (cardano-ledger `hashAlonzoSegWits`, the byte-exact authority — there
     is no prose spec for it) is a HASH-OF-FOUR-HASHES over the segwit segments, using
     each segment's ORIGINAL received bytes (NOT a re-encoding):

         body_hash = blake2b256(
             blake2b256(tx_bodies_bytes)    <>
             blake2b256(tx_witsets_bytes)   <>
             blake2b256(aux_data_bytes)     <>
             blake2b256(invalid_txs_bytes) )

  Preserving original segment bytes is why we decode the top-level array element by
  element, measuring each element's byte span (CBOR.decode returns the unconsumed
  rest, so span = size_before - size_after) rather than decoding the whole block and
  re-encoding (which would not be byte-faithful).
  """

  alias Cardamom.Crypto
  alias Cardamom.Ledger.Conway.Header

  @type t :: %__MODULE__{
          header: Header.t(),
          hash: <<_::256>>,
          tx_count: non_neg_integer(),
          raw: binary()
        }
  defstruct [:header, :hash, :tx_count, :raw]

  @doc """
  Decode a raw Conway block (the UNWRAPPED bytes — caller strips the block-fetch
  tag-24 envelope first). Returns `{:ok, %Block{}}` or `{:error, reason}`. The block
  is kept verbatim in `:raw` (hash fidelity). Strict: never raises.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(raw) when is_binary(raw) do
    with {:ok, [hdr_bytes, bodies_b, _wits_b, _aux_b, _invalid_b]} <- segments(raw),
         {:ok, header} <- Header.decode(hdr_bytes),
         {:ok, tx_count} <- count_txs(bodies_b) do
      {:ok,
       %__MODULE__{
         header: header,
         hash: header.hash,
         tx_count: tx_count,
         raw: raw
       }}
    end
  end

  def decode(_), do: {:error, :not_binary}

  @doc """
  Verify the body against the header's `block_body_hash` commitment (the tamper
  check). Returns `:ok` or `{:error, {:body_hash_mismatch, expected, got}}`.
  Recomputes the spec-exact hash-of-four-segwit-hashes over the ORIGINAL bytes.
  """
  @spec verify_body(t()) :: :ok | {:error, term()}
  def verify_body(%__MODULE__{raw: raw, header: header}) do
    with {:ok, [_hdr, bodies_b, wits_b, aux_b, invalid_b]} <- segments(raw) do
      computed =
        Crypto.blake2b_256(
          Crypto.blake2b_256(bodies_b) <>
            Crypto.blake2b_256(wits_b) <>
            Crypto.blake2b_256(aux_b) <>
            Crypto.blake2b_256(invalid_b)
        )

      if computed == header.block_body_hash do
        :ok
      else
        {:error, {:body_hash_mismatch, header.block_body_hash, computed}}
      end
    end
  end

  # ---- the span-extracting top-level walk ----

  # Split the block into its 5 elements' ORIGINAL byte slices. A real block is
  # wrapped in an ERA envelope: `[era, [header, bodies, wits, aux, invalid]]` (CONFIRMED
  # from real Preview block-fetch: `82 05 85 ...` = [era 5 (Conway), array(5)]). We
  # strip the era envelope to the inner 5-element block, then peel each element by
  # measuring CBOR.decode's consumed span. The body-hash is over the INNER block's
  # segments (the era wrapper isn't part of it). Also accept a BARE inner block (no
  # era wrapper) for SimPeer/older shapes.
  defp segments(raw) do
    with {:ok, inner} <- unwrap_era(raw),
         {:ok, rest0} <- array5_header(inner),
         {hdr, rest1} <- take(rest0),
         {bodies, rest2} <- take(rest1),
         {wits, rest3} <- take(rest2),
         {aux, rest4} <- take(rest3),
         {invalid, _rest5} <- take(rest4) do
      {:ok, [hdr, bodies, wits, aux, invalid]}
    else
      _ -> {:error, :bad_block_structure}
    end
  rescue
    _ -> {:error, :bad_block_structure}
  end

  # Strip the `[era, inner_block]` envelope, returning the inner block's ORIGINAL
  # bytes. `82` = array(2): era int, then the inner block. If it's already a bare
  # array(5) (`85...`), pass it through unchanged.
  defp unwrap_era(<<0x85, _::binary>> = bare), do: {:ok, bare}

  defp unwrap_era(<<0x82, _::binary>> = wrapped) do
    # [era, inner] — skip the array header + the era int, return the inner bytes.
    {_inner_term, after_era} = era_skip(wrapped)
    {:ok, after_era}
  end

  defp unwrap_era(_), do: {:error, :not_block_envelope}

  # Consume `82` (array-2 header) then the era integer; return {era, inner_bytes}.
  defp era_skip(<<0x82, rest::binary>>) do
    {:ok, era, inner} = CBOR.decode(rest)
    {era, inner}
  end

  # Consume the CBOR array-of-5 header byte. 0x85 = array(5) (definite, <24 items).
  defp array5_header(<<0x85, rest::binary>>), do: {:ok, rest}
  defp array5_header(_), do: {:error, :not_array5}

  # Decode one CBOR item off `bin`, returning {original_item_bytes, rest}. The item's
  # original bytes = the prefix of `bin` of length (size(bin) - size(rest)).
  defp take(bin) do
    {:ok, _term, rest} = CBOR.decode(bin)
    span = byte_size(bin) - byte_size(rest)
    <<item::binary-size(span), ^rest::binary>> = bin
    {item, rest}
  end

  # tx_count = number of items in the (already-isolated) tx_bodies array.
  defp count_txs(bodies_bytes) do
    case CBOR.decode(bodies_bytes) do
      {:ok, list, _} when is_list(list) -> {:ok, length(list)}
      _ -> {:error, :bad_tx_bodies}
    end
  end
end
