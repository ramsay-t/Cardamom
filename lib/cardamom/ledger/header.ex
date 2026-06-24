defmodule Cardamom.Ledger.Header do
  @moduledoc """
  Era-dispatching block-header decoder. The chain-sync header envelope is
  `[era_tag, #6.24(header_bytes)]` where `era_tag` is the 0-based HardFork CardanoEras index
  (ouroboros-consensus `Cardano/Block.hs`). This entry point reads that tag and routes the raw
  header bytes to the right per-era decoder, each of which strictly validates its era's exact
  CBOR shape and normalises to the shared `%Cardamom.Ledger.Conway.Header{}` struct.

      tag  era       protocol  decoder
      0    Byron     PBFT      Cardamom.Ledger.Byron.Header
      1    Shelley   TPraos    Cardamom.Ledger.Shelley.Header   (flat 15-field, two VRFs)
      2    Allegra   TPraos    Cardamom.Ledger.Shelley.Header
      3    Mary      TPraos    Cardamom.Ledger.Shelley.Header
      4    Alonzo    TPraos    Cardamom.Ledger.Shelley.Header
      5    Babbage   Praos     Cardamom.Ledger.Praos.Header     (nested 10-field, one VRF)
      6    Conway    Praos     Cardamom.Ledger.Praos.Header
      7    Dijkstra  Praos     Cardamom.Ledger.Praos.Header     (next HF; still Praos)

  An unknown era tag is an explicit error (we never guess a shape) — when a future hard fork
  adds a tag with a NEW header shape, this returns `{:error, {:unknown_era, tag}}` loudly
  rather than silently mis-decoding. (Praos covers 5..7; extend the range only against the
  spec, never by assumption.)
  """

  alias Cardamom.Ledger.Conway.Header, as: Normalised

  @byron 0
  @tpraos 1..4
  @praos 5..7

  @doc """
  Decode a header given its era tag and raw header bytes (the `#6.24` payload). For Byron the
  "raw" is the `[tag, header]` payload (the Byron decoder needs the whole thing for the hash);
  for TPraos/Praos it's the bare header bytes. `{:ok, h} | {:error, reason}`. Never raises.
  """
  @spec decode(integer(), binary()) :: {:ok, Normalised.t()} | {:error, term()}
  def decode(@byron, raw), do: Cardamom.Ledger.Byron.Header.decode(raw)
  def decode(era, raw) when era in @tpraos, do: Cardamom.Ledger.Shelley.Header.decode(raw)
  def decode(era, raw) when era in @praos, do: Cardamom.Ledger.Praos.Header.decode(raw)
  def decode(era, _raw) when is_integer(era), do: {:error, {:unknown_era, era}}
  def decode(_era, _raw), do: {:error, :bad_era_tag}
end
