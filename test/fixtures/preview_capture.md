# Real Preview wire-data fixtures

Captured from a live `cardamom` chain-sync session against the IOG Preview relay
`preview-node.play.dev.cardano.org:3001` on 2026-06-20 (see
`log/cardamom-20260620-094532-preview-firstcontact.log`). These are GENUINE
Cardano Preview bytes — used as regression fixtures so our decoders are pinned to
real wire data, network-free, every test run.

## Tip (from a RollForward), slot 115289152, block height 4400600

Wire shape: `tip = [ point, block_no ]`, `point = [ slot, header_hash ]`.

- `slot`       = 115289152
- `block_no`   = 4400600
- `header_hash` (32 bytes, blake2b-256), decimal as logged by Erlang:
  `211, 154, 84, 171, 33, 250, 68, 93, 84, 133, 210, 9, 104, 169, 20, 201, 230,
   200, 135, 243, 95, 231, 193, 179, 134, 5, 76, 182, 47, 129, 228, 40`
- header_hash hex: `d39a54ab21fa445d5485d20968a914c9e6c887f35fe7c1b386054cb62f81e428`

## Tip from an earlier RollBackward, slot 115289127, block height 4400599

- `slot`     = 115289127
- `block_no` = 4400599
- header_hash (32 bytes) decimal:
  `21, 149, 165, 185, 76, 14, 237, 152, 70, 3, 50, 58, 148, 24, 25, 172, 138, 6,
   154, 63, 43, 189, 47, 22, 101, 53, 131, 169, 203, 107, 142, 0`
- header_hash hex: `1595a5b94c0eed984603323a941819ac8a069a3f2bbd2f166535 83a9cb6b8e00`

## NOT yet captured

The full header BODY (block_number, slot, prev_hash, vrf, opcert, ...) was not
unwrapped in that session (logged `header_bytes: nil`). A future capture run with
`CARDAMOM_CAPTURE_HEADERS` will append raw header hex here to pin `Header.decode`
against real header bytes.
