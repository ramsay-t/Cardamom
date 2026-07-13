defmodule Cardamom.Ledger.Address do
  @moduledoc """
  Parse a Shelley-era address's STAKING (delegation) credential — the part that says which stake a
  UTxO's value counts toward. Needed for the stake distribution (reward engine). We store the raw
  `serialiseAddr` bytes for each output; this reads their structure. CIP-19 / Shelley CDDL.

  An address is `header_byte || payload`. The header's HIGH nibble is the address TYPE; the LOW
  nibble is the network id. Types (high nibble):

    0  base: payment KEY,    stake KEY        -> payment(28) || stake(28)
    1  base: payment SCRIPT, stake KEY        -> payment(28) || stake(28)
    2  base: payment KEY,    stake SCRIPT     -> payment(28) || stake(28)
    3  base: payment SCRIPT, stake SCRIPT     -> payment(28) || stake(28)
    4  pointer: payment KEY    + ptr          -> payment(28) || pointer(varint*3)  (stake = a pointer)
    5  pointer: payment SCRIPT + ptr          -> payment(28) || pointer
    6  enterprise: payment KEY,    NO stake    -> payment(28)
    7  enterprise: payment SCRIPT, NO stake    -> payment(28)
    14 reward/stake addr, stake KEY           -> stake(28)
    15 reward/stake addr, stake SCRIPT        -> stake(28)

  Byron addresses (type 8, an 0b1000_.... header) are legacy bootstrap and carry no staking info.

  Returns the staking credential as `{:key, hash28} | {:script, hash28}` (matching the credential
  shape our cert/delegation code uses), or `nil` when the address has no staking part (enterprise,
  pointer — we don't resolve pointers — Byron, or malformed). nil means "contributes to no
  delegated stake", which is correct for stake-distribution purposes.
  """

  import Bitwise

  @doc "The staking credential of an address, or nil if it has none / can't be determined."
  @spec stake_credential(binary()) :: {:key, binary()} | {:script, binary()} | nil
  def stake_credential(<<header, rest::binary>>) do
    type = header >>> 4

    case type do
      # base addresses: stake credential is the SECOND 28 bytes; its kind depends on the type bit.
      t when t in 0..3 ->
        case rest do
          <<_payment::binary-size(28), stake::binary-size(28)>> ->
            # types 0/1 → stake is a KEY; types 2/3 → stake is a SCRIPT (the 2s bit of the type).
            if (t &&& 2) == 0, do: {:key, stake}, else: {:script, stake}

          _ ->
            nil
        end

      # reward/stake address: the whole payload is the stake credential.
      t when t in 14..15 ->
        case rest do
          <<stake::binary-size(28)>> ->
            if t == 14, do: {:key, stake}, else: {:script, stake}

          _ ->
            nil
        end

      # enterprise (6/7): no stake part. pointer (4/5): stake is a pointer we don't resolve.
      # Byron (8) and anything else: no usable staking credential.
      _ ->
        nil
    end
  end

  def stake_credential(_), do: nil
end
