defmodule Cardamom.Ledger.Header do
  @moduledoc """
  Block-header decoder that dispatches on the header's OWN SELF-DESCRIBING SHAPE, not on the
  wire era tag.

  Why not the era tag: the `[era_tag, ...]` number is NOT a reliable discriminator — block-fetch
  and chain-sync number eras differently (block-fetch tags an Alonzo block 5; chain-sync tags a
  Babbage header 4), and the 15-field→10-field header change does NOT line up with the era index
  anyway (Alonzo AND Babbage are 15-field two-VRF; only Conway+ is 10-field combined-VRF). Trying
  to map tag→shape means guessing a mapping the wire doesn't actually honour. (This is the bug
  that froze body backfill: era 5 was dispatched to the 10-field decoder, but those blocks are
  15-field, so every one was rejected.)

  The header IS self-describing: it is `[header_body, kes_signature]`, and the CBOR array length
  of `header_body` says which shape it is — no era tag required:

    * 15 elements → TPraos / pre-combined-VRF Praos (Shelley … Babbage): two VRF certs, OCert +
      ProtVer inlined. → `Cardamom.Ledger.Shelley.Header`. Verified: real Alonzo (proto 6) and
      Babbage (proto 7) blocks are 15-field.
    * 10 elements → combined-VRF Praos (Conway+): one VRF cert, nested OCert + ProtVer.
      → `Cardamom.Ledger.Praos.Header`. Verified: real Conway (proto 8) headers are 10-field.

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
