#!/usr/bin/env bash
# Dump real stored block bytes from the production store to flat hex FIXTURE files,
# so tests + offline replay can read real blocks WITHOUT a populated ChainStore/DB
# (the test DB is a fresh, empty, throwaway forest-<test-magic>.db).
#
#   scripts/dump_block_fixtures.sh [N]    # dump the first N blocks (default 10)
#
# Writes test/fixtures/blocks/block-<block_no>.hex (lowercase hex of blocks.raw),
# each a complete, verbatim, hash-verified block. Run after a block-fetch has
# populated data/forest-2.db.
set -euo pipefail

N="${1:-10}"
DB="data/forest-2.db"
OUT="test/fixtures/blocks"

if [ ! -f "$DB" ]; then
  echo "no store at $DB — run a block-fetch first" >&2
  exit 1
fi

mkdir -p "$OUT"
count=0

# block_no + lowercase hex of raw, slot-ordered, first N.
while IFS='|' read -r block_no hex; do
  printf '%s' "$hex" | tr 'A-F' 'a-f' > "$OUT/block-${block_no}.hex"
  count=$((count + 1))
done < <(sqlite3 "$DB" "SELECT block_no, hex(raw) FROM blocks ORDER BY slot LIMIT ${N};")

echo "dumped ${count} block fixtures to ${OUT}/ (from ${DB})"
ls -1 "$OUT" | head
