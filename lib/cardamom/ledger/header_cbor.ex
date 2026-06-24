defmodule Cardamom.Ledger.HeaderCBOR do
  @moduledoc """
  Shared CBOR helpers for the per-era header decoders (Byron / Shelley-TPraos / Praos).

  Every era's decoder needs the same primitives: pull a byte string out of the cbor lib's
  `%CBOR.Tag{tag: :bytes}` wrapper, decode a top-level CBOR term, hex a hash. Keeping them in
  one place stops the three decoders drifting. Nothing here interprets a header — that's each
  era's job; this is purely the byte/CBOR plumbing.
  """

  @doc "The cbor lib decodes byte strings to %CBOR.Tag{tag: :bytes}; unwrap to the raw binary."
  def bytes(%CBOR.Tag{tag: :bytes, value: v}), do: v
  def bytes(b) when is_binary(b), do: b
  def bytes(other), do: other

  @doc "nil prev-hash (genesis / era start) stays nil; otherwise unwrap the 32-byte hash."
  def prev_hash(nil), do: nil
  def prev_hash(h), do: bytes(h)

  @doc "Decode one top-level CBOR term. `{:ok, term, rest}` | `{:error, {:cbor, reason}}`."
  def cbor_decode(raw) do
    case CBOR.decode(raw) do
      {:ok, term, rest} -> {:ok, term, rest}
      {:error, e} -> {:error, {:cbor, e}}
    end
  end

  @doc "lowercase hex of a binary (for hash_hex etc.)."
  def hex(bin), do: Base.encode16(bin, case: :lower)
end
