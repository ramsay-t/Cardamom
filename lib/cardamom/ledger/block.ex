defmodule Cardamom.Ledger.Block do
  @moduledoc """
  Era-dispatching entry point for decoding a block's transactions. A block arrives
  era-wrapped — `[era, inner]` — where `era` is the HardFork `CardanoEras` index:

      0 Byron, 1 Shelley, 2 Allegra, 3 Mary, 4 Alonzo, 5 Babbage, 6 Conway, 7 Dijkstra.

  Byron (era 0) is structurally unrelated to every later era and is decoded by
  `Cardamom.Ledger.Byron.Body`. Eras 1-7 are the Shelley FAMILY: they all share the
  `[header, tx_bodies, witness_sets, aux, invalid_transactions]` block shape and an
  upward-compatible transaction_body, so a single decoder (`Cardamom.Ledger.Conway.Tx`)
  handles all of them — it already reads only the keys present-or-absent per era (Shelley
  has no multiasset/datums/collateral; Mary+ adds multiasset; Alonzo+ adds datums +
  collateral + is_valid; Babbage+ adds inline datums / reference inputs / map outputs).

  Both decoders normalise to the SAME tx/output map shape so ChainStore stores every era's
  TXOs uniformly: `%{txid, valid, inputs, outputs: [%{address, value, multiasset, datum_hash,
  datum, raw}], reference_inputs, collateral_inputs, collateral_return, fee, mint}`.

  Strict: an unknown era tag → `{:error, {:unknown_era, tag}}`.
  """

  alias Cardamom.Ledger.Byron
  alias Cardamom.Ledger.Conway

  # HardFork CardanoEras indices (see moduledoc).
  @byron 0
  @shelley_family 1..7

  @doc """
  Decode a block's transactions, reading the era tag from the `[era, inner]` envelope itself.
  Falls back to the Shelley-family decoder for a bare (un-era-wrapped) array-5 block, since
  that shape only exists for Shelley+ (Byron is never bare in our pipeline).
  """
  @spec txs_in(binary()) :: {:ok, [map()]} | {:error, term()}
  def txs_in(raw) when is_binary(raw) do
    case era_tag(raw) do
      {:ok, tag} -> txs_in(tag, raw)
      # No readable era tag (e.g. a bare array-5 block, or a standalone shape): the only
      # un-era-wrapped blocks we see are Shelley+, so route them there.
      :error -> Conway.Tx.txs_in(raw)
    end
  end

  def txs_in(_), do: {:error, :not_binary}

  @doc """
  Decode a block's transactions with an EXPLICIT era tag (when the caller already has it,
  e.g. from the block-fetch envelope it just parsed). Routes Byron vs Shelley-family.
  """
  @spec txs_in(non_neg_integer(), binary()) :: {:ok, [map()]} | {:error, term()}
  def txs_in(@byron, raw) when is_binary(raw), do: Byron.Body.txs_in(raw)

  def txs_in(tag, raw) when tag in @shelley_family and is_binary(raw),
    do: Conway.Tx.txs_in(raw)

  def txs_in(tag, raw) when is_integer(tag) and is_binary(raw),
    do: {:error, {:unknown_era, tag}}

  def txs_in(_, _), do: {:error, :not_binary}

  # Read the era tag from a `[era, inner]` envelope (0x82 = array-2, first element the era
  # int). A bare array-5 block (0x85) has no era tag → :error (caller defaults it).
  defp era_tag(<<0x82, rest::binary>>) do
    case CBOR.decode(rest) do
      {:ok, era, _inner} when is_integer(era) -> {:ok, era}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp era_tag(_), do: :error
end
