defmodule Cardamom.Ledger.Header do
  @moduledoc """
  Block-header decoder that dispatches on the header's OWN SELF-DESCRIBING SHAPE, not on the
  wire era tag.

  Why not the era tag: the `[era_tag, ...]` number is NOT a reliable discriminator — block-fetch
  and chain-sync number eras DIFFERENTLY (resolved 2026-07-24, see docs/WIRE.md §9: the block
  envelope is the consensus DISK encoding where Byron occupies TWO tags — 0 EBB, 1 regular — so
  Shelley=2 … Alonzo=5, Babbage=6, Conway=7; the chain-sync header envelope gives Byron ONE slot,
  so every later era is one lower: Alonzo=4, Babbage=5, Conway=6). Mapping tag→shape means
  knowing which numbering you're holding — guess wrong and every block rejects. (This is the bug
  that froze body backfill: block tag 5 was assumed Babbage/10-field via the wrong table, but
  block-tag 5 is ALONZO and those headers are 15-field, so every one was rejected.)

  The header IS self-describing: it is `[header_body, kes_signature]`, and the CBOR array length
  of `header_body` says which shape it is — no era tag required:

    * 15 elements → TPraos (Shelley … Alonzo): two VRF certs, OCert + ProtVer inlined.
      → `Cardamom.Ledger.Shelley.Header`. Verified against real Alonzo-era Preview blocks — NB
      their ProtVer field may signal proto 7 (a late-Alonzo block voting for the Vasil HF);
      proto-version ≠ era, another of the four version axes.
    * 10 elements → Praos (Babbage+, incl. Conway/Dijkstra): one combined VRF cert, nested
      OCert + ProtVer. → `Cardamom.Ledger.Praos.Header`. Verified against real Babbage-era
      Preview headers.

  Byron (era 0) headers are structurally different — `[tag, header]`, not `[body, sig]` — so
  Byron is taken only when the era tag explicitly says 0 (Byron never reaches the array-length
  branch). For the Shelley family the era tag is IGNORED; the bytes decide.

  All decoders normalise to the shared `%Cardamom.Ledger.Conway.Header{}` struct.
  """

  alias Cardamom.Ledger.Conway.Header, as: Normalised
  import Cardamom.Ledger.HeaderCBOR, only: [cbor_decode: 1]

  @byron 0

  @doc """
  Decode a header. `era_tag` selects Byron (0) only; for everything else the SHAPE of the bytes
  (header_body array length) chooses the decoder. For Byron the `raw` is the `[tag, header]`
  payload (its decoder needs the whole thing for the hash); otherwise it's the bare header
  bytes. `{:ok, h} | {:error, reason}`. Never raises.
  """
  @spec decode(integer(), binary()) :: {:ok, Normalised.t()} | {:error, term()}
  def decode(@byron, raw), do: Cardamom.Ledger.Byron.Header.decode(raw)

  def decode(_era, raw) when is_binary(raw) do
    case header_body_length(raw) do
      {:ok, 15} -> Cardamom.Ledger.Shelley.Header.decode(raw)
      {:ok, 10} -> Cardamom.Ledger.Praos.Header.decode(raw)
      {:ok, n} -> {:error, {:unknown_header_shape, n}}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(_era, _raw), do: {:error, :not_binary}

  # The header is [header_body, kes_signature]; return the CBOR array length of header_body — the
  # self-describing shape discriminator. We decode the outer term (cheap) and measure the body
  # list; this never trusts an era tag.
  defp header_body_length(raw) do
    case cbor_decode(raw) do
      {:ok, [body, _sig], _rest} when is_list(body) -> {:ok, length(body)}
      {:ok, other, _rest} -> {:error, {:not_a_header, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
