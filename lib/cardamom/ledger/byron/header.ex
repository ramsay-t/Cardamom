defmodule Cardamom.Ledger.Byron.Header do
  @moduledoc """
  Decoder for the **Byron** block header (era 0) as sent over node-to-node chain-sync.

  Byron is genuinely different from every later (Shelley+) era: no VRF, no KES operational
  certificate, PBFT consensus with heavyweight delegation, and TWO header sub-shapes — the
  regular main-block header and the epoch-boundary block (EBB / "boundary") header.

  SOURCE OF TRUTH: `cardano-ledger/eras/byron/ledger/impl/.../Cardano/Chain/Block/Header.hs`.

  ON THE WIRE: the chain-sync `#6.24(bytes)` payload for Byron is `encCBORHeaderToHash` =
  `[Word tag, header]` (Header.hs:406-408) — a 2-element array whose first element is the tag:

      tag 1 → regular header   (encCBORHeader, Header.hs:297-309): a 5-element array
                [protocolMagicId, prevHash, bodyProof,
                 [slot=(epoch,slotcount), genesisKey, difficulty, blockSig],   -- consensus data
                 blockVersions]
      tag 0 → boundary/EBB     (encCBORABoundaryHeader, Header.hs:546-567): a 5-element array
                [protocolMagic, prevHash, bodyProof,
                 [epoch, difficulty],                                          -- consensus data
                 [genesisTag]]                                                 -- extra data

  HASH: `hashHeader = blake2b_256 . serialize . encCBORHeaderToHash` (Header.hs:496-497;
  HeaderHash = AbstractHash Blake2b_256, Hashing.hs:261). encCBORHeaderToHash IS the
  `[tag, header]` bytes — which is exactly the payload we receive. So the Byron header hash is
  `blake2b_256(payload)` over the WHOLE `[tag, header]` payload — we must NOT strip the tag
  before hashing (unlike Praos/TPraos, where the payload is the bare header). `wrapHeaderBytes`
  / `wrapBoundaryBytes` (the `82 01` / `82 00` prefixes) are simply that 2-list-with-tag prefix.

  Normalises to `%Cardamom.Ledger.Conway.Header{}` (the shared, store-compatible struct), with
  the Byron-absent fields (vrf_*, operational_cert) left nil. For a regular block: block_number
  = chain difficulty, issuer_vkey = genesisKey. For an EBB: there is no slot or issuer; slot is
  reported nil and block_number = difficulty.
  """

  alias Cardamom.Crypto
  alias Cardamom.Ledger.Conway.Header, as: Normalised
  import Cardamom.Ledger.HeaderCBOR

  # Byron EpochSlots (slots per epoch) = 10 * k. k = 2160 on mainnet AND Preprod (the only nets
  # that have a Byron era), so 21600. SOURCE: byron Slotting/EpochAndSlotCount.hs toSlotNumber
  # (absolute_slot = epoch * EpochSlots + slot_in_epoch) + the well-known k=2160. A bespoke net
  # with a different k would need this overridden, but no live Cardano net does.
  @byron_epoch_slots 21_600

  @doc """
  Decode the RAW Byron chain-sync header payload (`[tag, header]`, the `#6.24` bytes) into a
  normalised `%Cardamom.Ledger.Conway.Header{}`. `{:ok, h} | {:error, reason}`. Never raises.

  Hashes the WHOLE payload (tag included) — that's the Byron header hash.
  """
  @spec decode(binary()) :: {:ok, Normalised.t()} | {:error, term()}
  def decode(raw) when is_binary(raw) do
    with {:ok, term, _rest} <- cbor_decode(raw),
         {:ok, body} <- decode_tagged(term) do
      hash = Crypto.blake2b_256(raw)
      {:ok, struct(Normalised, Map.merge(body, %{hash: hash, hash_hex: hex(hash), raw_size: byte_size(raw)}))}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  def decode(_), do: {:error, :not_binary}

  # [tag, header]: 1 = regular, 0 = boundary/EBB.
  defp decode_tagged([1, header]), do: decode_regular(header)
  defp decode_tagged([0, header]), do: decode_boundary(header)
  defp decode_tagged(other), do: {:error, {:not_a_byron_header, other}}

  # Regular: [magic, prevHash, bodyProof, [slot, genesisKey, difficulty, sig], blockVersions]
  defp decode_regular([
         _protocol_magic,
         prev_hash,
         body_proof,
         [slot_pair, genesis_key, difficulty, _block_sig],
         _block_versions
       ])
       when is_integer(difficulty) do
    {:ok,
     %{
       block_number: difficulty,
       slot: byron_slot(slot_pair),
       prev_hash: prev_hash(prev_hash),
       issuer_vkey: bytes(genesis_key),
       vrf_vkey: nil,
       vrf_result: nil,
       vrf_result_2: nil,
       # Byron has no separate body-size in the header; body integrity is the bodyProof.
       block_body_size: nil,
       block_body_hash: bytes(body_proof),
       operational_cert: nil,
       # Byron blocks predate ProtVer-as-(major,minor); report era 0.
       protocol_version: {0, 0}
     }}
  end

  defp decode_regular(other), do: {:error, {:bad_byron_regular_header, other}}

  # Boundary/EBB: [magic, prevHash, bodyProof, [epoch, difficulty], [genesisTag]]
  defp decode_boundary([
         _protocol_magic,
         prev_hash,
         body_proof,
         [_epoch, difficulty],
         _extra
       ])
       when is_integer(difficulty) do
    {:ok,
     %{
       block_number: difficulty,
       # An EBB sits between epochs and carries no slot.
       slot: nil,
       prev_hash: prev_hash(prev_hash),
       issuer_vkey: nil,
       vrf_vkey: nil,
       vrf_result: nil,
       vrf_result_2: nil,
       block_body_size: nil,
       block_body_hash: bytes(body_proof),
       operational_cert: nil,
       protocol_version: {0, 0}
     }}
  end

  defp decode_boundary(other), do: {:error, {:bad_byron_boundary_header, other}}

  # Byron slot is [epoch, slotInEpoch]; flatten to an ABSOLUTE SlotNo (an integer, like every
  # later era) so the store/Forest see a uniform slot. absolute = epoch*EpochSlots + slot_in_epoch
  # (byron Slotting/EpochAndSlotCount.hs toSlotNumber). nil if the shape is unexpected (caller
  # treats a nil-slot header as a decode that produced no usable slot — not coerced to 0).
  defp byron_slot([epoch, slot_in_epoch]) when is_integer(epoch) and is_integer(slot_in_epoch),
    do: epoch * @byron_epoch_slots + slot_in_epoch

  defp byron_slot(_other), do: nil
end
