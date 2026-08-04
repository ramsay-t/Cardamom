# VRF test vectors (ECVRF draft-03, Cardano "praos" variant)

Two known-good sources, one purpose: pin our ECVRF verifier to reality before it
gates anything.

## `vrf_ver03_standard_*` / `vrf_ver03_generated_*`

The official vector files from IOG's own crypto test suite — fetched verbatim
(2026-08-04) from `IntersectMBO/cardano-base`
(`cardano-crypto-praos/test_vectors/`, Apache-2.0). The `standard_10..12` files
are the IETF draft-03 §A.4 vectors for `ECVRF-ED25519-SHA512-Elligator2`; the
`generated_*` files are IOG-produced. These are the exact bytes the Haskell
node's libsodium-fork binding is tested against, so agreement here means
agreement with the production implementation. Format: `field: hexvalue` lines
(`alpha: empty` = zero-length input); fields: sk, pk, alpha, pi (80-byte
proof), beta (64-byte output). We use the verify-side fields (pk, alpha, pi,
beta); sk is unused (verify-only implementation).

## `real_headers_praos.tsv`

300 random Praos-shape (10-field) headers from our stored, body-verified
Preview chain: `slot ⟂ vrf_vkey ⟂ vrf_output ⟂ vrf_proof` (hex, tab-separated).
Every proof here was accepted by the real network. Two validation stages:

* **Stage A (no epoch nonce needed):** the 64-byte output must equal the
  proof's derived output `SHA512(suite ‖ 0x03 ‖ cofactor·Γ)` — pins point
  decompression, cofactor handling, and output derivation against 300 real
  proofs.
* **Stage B (needs η):** full `verify(vk, π, blake2b(slot ‖ η))` — becomes the
  leader-election oracle once nonce evolution lands.

Regenerate: export `slot, hex(raw)` for random stored headers, then run the
corpus script (see git history / CLAUDE notes) — decodes each header and
extracts the VRF cert fields.
