defmodule Cardamom.Store.Header do
  @moduledoc """
  A header row in the durable store — the forest, persisted. Follows the store's
  rule: keep the RAW bytes verbatim (hash fidelity — a header's hash is over its
  exact CBOR) AND decode the forensically-interesting fields into typed columns, so
  we can run meaningful queries ("blocks by issuer", "when did protocol vN appear",
  body-size analysis) without re-parsing blobs.

  `hash` is the real blake2b-256 identity (primary key). Stands alone WITHOUT block
  bodies while trust-everything: following the chain and resuming need only headers.

  Columns are the queryable subset of the 15-field Praos header (see
  `Cardamom.Ledger.Conway.Header`). The bulky VRF proof blobs are NOT columned (huge,
  rarely queried) — they remain recoverable from `raw` if ever needed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:hash, :binary, autogenerate: false}
  schema "headers" do
    field :prev_hash, :binary
    field :slot, :integer
    field :block_no, :integer
    # Forensic columns (decoded):
    field :issuer_vkey, :binary
    field :vrf_vkey, :binary
    field :block_body_size, :integer
    field :block_body_hash, :binary
    field :protocol_major, :integer
    field :protocol_minor, :integer
    # Verbatim wire bytes (the truth; hash fidelity):
    field :raw, :binary
  end

  @fields [
    :hash,
    :prev_hash,
    :slot,
    :block_no,
    :issuer_vkey,
    :vrf_vkey,
    :block_body_size,
    :block_body_hash,
    :protocol_major,
    :protocol_minor,
    :raw
  ]
  @required [:hash, :slot, :block_no, :raw]

  def changeset(header, attrs) do
    header
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end

  @doc """
  Build the row attrs from a decoded `Cardamom.Ledger.Conway.Header` struct + its raw
  bytes. The single place header→row mapping lives, so the decoded fields and the
  raw bytes are stored together.
  """
  def from_decoded(%Cardamom.Ledger.Conway.Header{} = h, raw) when is_binary(raw) do
    {major, minor} = h.protocol_version

    %{
      hash: h.hash,
      prev_hash: h.prev_hash,
      slot: h.slot,
      block_no: h.block_number,
      issuer_vkey: h.issuer_vkey,
      vrf_vkey: h.vrf_vkey,
      block_body_size: h.block_body_size,
      block_body_hash: h.block_body_hash,
      protocol_major: major,
      protocol_minor: minor,
      raw: raw
    }
  end
end
