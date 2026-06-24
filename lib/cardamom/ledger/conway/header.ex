defmodule Cardamom.Ledger.Conway.Header do
  @moduledoc """
  The shared, NORMALISED block-header struct that every era's decoder produces, and the
  store/forest consume. Despite the `Conway` name (kept so `ChainStore`/`Store.Header`, which
  pattern-match this struct, don't churn), this is era-INDEPENDENT: a Byron, TPraos, or Praos
  header all decode into this same shape via `Cardamom.Ledger.Header.decode/2`.

  Fields a later era doesn't have are nil (Byron has no vrf_*/operational_cert; Praos has a
  single VRF so `vrf_result_2` is nil). The actual era-specific CBOR shapes live in:

    * `Cardamom.Ledger.Byron.Header`   (era 0)
    * `Cardamom.Ledger.Shelley.Header` (eras 1-4, TPraos, flat 15-field, two VRFs)
    * `Cardamom.Ledger.Praos.Header`   (eras 5-7, Praos, nested 10-field, one VRF)

  `decode/1` here remains as a BACK-COMPAT alias for the TPraos shape (delegates to
  `Shelley.Header`) — the era-4 fixture and older tests call it. New code should call the
  era-dispatching `Cardamom.Ledger.Header.decode/2`.

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
  BACK-COMPAT alias: decode RAW header bytes assuming the TPraos (Shelley-family, flat 15-field)
  shape, into a `%Header{}`. The era-4 Preview fixture and older tests call this directly. New
  code should use the era-dispatching `Cardamom.Ledger.Header.decode/2`, which picks the right
  per-era decoder. Delegates to `Cardamom.Ledger.Shelley.Header` (the actual home of this shape).
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  defdelegate decode(raw), to: Cardamom.Ledger.Shelley.Header
end
