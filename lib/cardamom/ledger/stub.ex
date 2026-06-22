defmodule Cardamom.Ledger.Stub do
  @moduledoc """
  Trust-everything stub `Cardamom.Ledger`. It does NOT decode header fields
  (that's a real era-specific ledger's job — Conway header structure lives in
  cardano-ledger). It provides the era-INDEPENDENT part: the header's identity,
  i.e. the blake2b-256 hash of its raw bytes. That's enough to:
    * give every header a stable, unique point (so the sync cursor visibly
      advances — each block has a distinct hash),
    * chain-link headers later (parent-hash matching) without field decode.

  The header HASH is the REAL Cardano hash: blake2b-256 of the raw header bytes
  (verified against the standard test vector). So a header's identity here matches
  the identity a real Cardano node computes — they can be compared directly.

  Slot and parent-hash are reported as not-yet-decoded until a real era ledger
  impl decodes the header body (Conway header_body: block_number, slot,
  prev_hash, ...). The stub deliberately decodes NOTHING — it only hashes — so
  there is no fake-but-plausible field data to mislead debugging.
  """

  @behaviour Cardamom.Ledger

  @impl Cardamom.Ledger
  def header_point(_handle, raw_header) when is_binary(raw_header) do
    hash = Cardamom.Crypto.blake2b_256(raw_header)

    {:ok,
     %{
       slot: :unknown,
       hash: hash,
       hash_hex: Base.encode16(hash, case: :lower)
     }}
  end

  def header_point(_handle, _other), do: {:error, :not_raw_header_bytes}
end
