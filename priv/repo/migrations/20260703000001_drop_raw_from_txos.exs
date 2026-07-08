defmodule Cardamom.Store.Repo.Migrations.DropRawFromTxos do
  use Ecto.Migration

  # DROP txos.raw — it was REDUNDANT. A txo's output bytes are wholly CONTAINED in the block that
  # created it (block = [hdr, [tx_body…], …]), and we keep blocks.raw (load-bearing: the reconciler
  # re-extracts from it, and a RELAY serves those exact bytes on the wire). So a txo's bytes are
  # recoverable on demand via Conway.Tx.txs_in(blocks.raw) → tx → output[ix] (which carves
  # byte-exact spans). Worse, txos.raw wasn't even the original span — decode_output stored a
  # RE-ENCODE (CBOR.encode([addr, value | rest])), so it duplicated ~155 B/row (~1.35 GB over 8.7M
  # rows) of bytes we already hold canonically in blocks.raw. No code READS a txo's raw. The txo
  # row keeps what queries need: address, value, datum(_hash), spend state, slots. (datum stays —
  # rare, ~13 B, and answers goal (b) "current datum of contract XYZ" as a direct lookup.)
  #
  # mempool_txo.raw is left ALONE: a pending mempool output isn't in any block yet, so its bytes
  # are NOT in blocks.raw — that raw is not redundant.
  def change do
    alter table(:txos) do
      remove :raw, :binary
    end
  end
end
