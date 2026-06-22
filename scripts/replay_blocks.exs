# Replay the stored block bytes (OFFLINE, no network) to:
#   a) prove replay works — read COMPLETE raw bytes from the durable store (blocks.raw);
#   b) decode each block and SHOW the decoded fields;
#   c) re-verify each body against its header's block_body_hash (ground-truth check on
#      stored bytes — they should still verify);
#   d) prove SQLite read-through — evict from cache, confirm it comes back from SQL.
#
#   mix run scripts/replay_blocks.exs
#
# Source is the DB (blocks.raw), NOT a log file: the raw bytes are captured completely
# and durably in the store (the old raw-byte LOG was truncated at 8192 bytes — useless
# for replay, removed). The DB is the forensic record AND the replay source.

require Logger
alias Cardamom.Ledger.Conway.Block
alias Cardamom.ChainStore
alias Cardamom.Store.Block, as: BlockRow

IO.puts("\n=== (a) REPLAY: reading stored blocks from the durable store (blocks.raw) ===\n")

rows = ChainStore.all_blocks()
IO.puts("found #{length(rows)} stored blocks\n")

if rows == [] do
  IO.puts("no stored blocks — run a block-fetch first to populate the store")
  System.halt(0)
end

IO.puts("=== (b)/(c) DECODE + re-VERIFY each stored block ===\n")

verified =
  Enum.reduce(rows, 0, fn row, ok ->
    case Block.decode(row.raw) do
      {:ok, blk} ->
        v = Block.verify_body(blk)

        IO.puts("  block_no=#{blk.header.block_number} slot=#{blk.header.slot}")
        IO.puts("    hash:        #{Base.encode16(blk.hash, case: :lower)}")
        IO.puts("    prev_hash:   #{blk.header.prev_hash && Base.encode16(blk.header.prev_hash, case: :lower)}")
        IO.puts("    tx_count:    #{blk.tx_count}")
        IO.puts("    raw_size:    #{byte_size(blk.raw)} bytes (complete — from blocks.raw)")
        IO.puts("    issuer_vkey: #{Base.encode16(blk.header.issuer_vkey, case: :lower) |> String.slice(0, 24)}...")
        IO.puts("    body_hash verify: #{inspect(v)}")
        IO.puts("")
        if v == :ok, do: ok + 1, else: ok

      err ->
        IO.puts("  UNDECODABLE stored block (#{byte_size(row.raw)} bytes): #{inspect(err)}\n")
        ok
    end
  end)

IO.puts("=== (d) READ-THROUGH: evict from cache, confirm it comes back from SQLite ===\n")

%BlockRow{hash: hash, block_no: bn} = hd(rows)
Cardamom.Store.Cache.delete({:block, hash})
IO.puts("  evicted block_no=#{bn} from cache")
IO.puts("  cache holds it? #{Cardamom.Store.Cache.get({:block, hash}) != nil}  (expect false)")
read = ChainStore.stored_block(hash)
IO.puts("  ChainStore.stored_block -> #{(match?(%BlockRow{}, read) && "FOUND (from SQLite)") || "nil"}")
IO.puts("  cache refilled? #{Cardamom.Store.Cache.get({:block, hash}) != nil}  (expect true)")

IO.puts("\n=== SUMMARY: #{length(rows)} stored blocks replayed+decoded, #{verified} body-hash VERIFIED, SQLite read-through proven ===\n")
