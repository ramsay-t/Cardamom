# WIRE.md — an observer's guide to the Cardano node-to-node wire

*What actually travels over a Cardano N2N connection, byte by byte — written
from a from-scratch client implementation (Cardamom) built against the Preview
testnet, with every claim pinned by a real captured fixture and a passing test
where one exists. Last revised 2026-07-23.*

**What this is.** The official CDDL grammars (see `network-specs.md` for the
full spec landscape) define the message encodings; this guide covers what they
*don't*: the transport framing, the envelope layers around headers and blocks,
the era-tag numbering, the behavioural expectations that get a peer
disconnected, and the gotchas that cost us real debugging time. Read it as a
companion to the CDDL, not a replacement.

**What this is not.** Cardamom's decoders are *permissive observers*, not
validators — "our decoder accepts it" does not mean "it is valid Cardano data"
(two of our own bugs decoded wrong data without noticing). Where validity
matters, the CDDL + ledger rules are the authority.

**Conformance vectors.** Fixtures live in `test/fixtures/` (hex dumps of real
Preview traffic and real Preview blocks); the tests that pin each
interpretation are cited per section. If you are building your own client,
these fixtures are directly reusable test inputs.

---

## 1. Transport: the mux SDU

Everything below rides in mux **Segment Data Units** over one TCP connection.
8-byte big-endian header, then payload:

```
bytes 0-3  transmission time  u32, microsecond ticks of a monotonic clock (wraps ~72 min)
bytes 4-5  (M << 15) | mini-protocol number     M: 0 = initiator, 1 = responder
bytes 6-7  payload length     u16
then       exactly `length` payload bytes
```

*Spec:* `network-spec/mux.tex` §Wire Format; *reference:* `Network.Mux.Codec`.
*Our codec:* `lib/cardamom/mux/sdu.ex`. **Beware:** the comment inside
`Codec.hs` states the mode bit backwards; the spec and the code's behaviour
agree on 0 = initiator. As a dialing client you always send M = 0.

The standard socket bearer caps SDU payloads at **12,288 bytes**
(`Bearer.hs`), well under the u16 maximum.

**Reassembly is not optional.** Two things happen routinely:

* one logical message **spans several SDUs** (any non-trivial block does);
* several whole messages are **packed into one SDU** (a relay glues a batch's
  last `MsgBlock` and `MsgBatchDone` together).

So the receive loop must: concatenate carried-over tail + new payload, decode
*every whole message* present, and carry the trailing partial forward. A codec
therefore needs three-way results: `{:ok, msg, rest}` / `:incomplete` /
`{:error, …}` — a short read is *not* an error. (Missing this cost us a
"relay stalls at block ~500" bug that was really our own dropped fragments.)
*Our implementation:* `lib/cardamom/mux/reassembler.ex`, shared by all
protocols so the logic cannot drift.

## 2. Mini-protocol numbers and conduct

| # | Protocol | Direction of drive |
|--:|---|---|
| 0 | handshake | initiator proposes |
| 2 | chain-sync | client pulls |
| 3 | block-fetch | client pulls |
| 4 | tx-submission2 | **server pulls** (asymmetric!) |
| 8 | keep-alive | client pings |
| 10 | peer-sharing | client asks |

(Wire numbers appear in the SDU header. They are *not* in the formal model,
which names protocols; they are in `network-spec/miniprotocols.tex` and the
CDDLs.)

The real node enforces, per state, and **closes the connection** on violation:
1. **agency** — a message sent in a state where you lack agency, with wrong
   arity, or an unknown tag;
2. **size limits**;
3. **timeouts** — e.g. after `MsgAwaitReply` the server has 601–911s to
   deliver; an idle connection without keep-alive traffic is reaped (we
   measured: handshake + chain-sync but no keep-alive pings → dropped at
   ~97s).

Every message below is a CBOR array with a leading integer tag.

## 3. Handshake (protocol 0) — first bytes on the wire

```
[0, versionTable]              propose    (versionTable: definite-length map version → data)
[1, version, versionData]      accept
[2, refuseReason]              refuse
[3, versionTable]              query reply
```

v14 `versionData = [networkMagic:u32, initiatorOnlyDiffusionMode:bool,
peerSharing:0|1, query:bool]`. Preview's `networkMagic = 2` (from its shelley
genesis; wrong value = instant refuse). `initiatorOnlyDiffusionMode = true`
declares "I dial, I don't serve" — the observer role is first-class in the
handshake.

Gotchas:
* The CDDL notes the codec **only accepts definite-length maps** for the
  version table. (The hex `cbor` library emits definite-length by default —
  verify yours does.)
* A `refuse` with reason `versionMismatch` carries a **list of version
  numbers** — a list of small ints, which naive CBOR decoding in some
  libraries (ours included) hands back as a *charlist/string* (`[14]` ≡
  `~c"\\x0e"`). Normalise at the codec boundary.

*Our codec + tests:* `lib/cardamom/protocol/handshake/codec.ex`,
`test/cardamom/protocol/handshake/`.

## 4. Chain-sync (protocol 2)

```
[0]                      RequestNext          client, StIdle
[1]                      AwaitReply           server (you're at tip; wait in StMustReply)
[2, header, tip]         RollForward
[3, point, tip]          RollBackward
[4, [point…]]            FindIntersect        client, StIdle
[5, point, tip]          IntersectFound
[6, tip]                 IntersectNotFound
[7]                      Done                 client, StIdle
```

FSM: `StIdle → StCanAwait → (AwaitReply) → StMustReply`, plus `StIntersect` —
see the Agda model (`ChainSync.agda`) or `miniprotocols.tex`.

**Points.** A point is `[slot, hash]` or `[]` (origin). The hash MUST be a
CBOR **byte** string (`#bytes(h)`). Encoding it as a raw binary produces a
CBOR *text* string — the relay rejects the message and **closes the
connection** (this was our first live disconnect: a resume `FindIntersect`
with text-string hashes).

**Tips.** `tip = [point, blockNo]` — kept opaque in our codec.

**The RollForward header envelope.** `header` is NOT bare header bytes; it is

```
[era, #6.24(header-bytes)]      ; CBOR tag 24 = "encoded CBOR data item"
```

Strip the envelope, keep the **exact** inner bytes: the header hash is
blake2b-256 of those received bytes, and hashing any re-encoding will not
match the chain. *Fixture:* `preview_rollforward.hex` (a real RollForward:
`[2, [4, #6.24(…)], tip]`); *tests:* `test/cardamom/ledger/header_test.exs`,
`conway/header_real_test.exs`.

*Codec:* `lib/cardamom/protocol/chain_sync/codec.ex`; envelope handling in
`lib/cardamom/chain_sync/client.ex` (`unwrap_header`).

## 5. Block-fetch (protocol 3)

```
[0, point, point]   RequestRange (inclusive; a RANGE, not a set — order is intrinsic)
[1]                 ClientDone
[2]                 StartBatch
[3]                 NoBlocks
[4, #6.24(bytes)]   Block        (one block, tag-24 wrapped like headers)
[5]                 BatchDone
```

Same point encoding (and the same byte-string trap) as chain-sync. Blocks
stream in chain order within a batch; a batch of hundreds of blocks arrives as
a long multi-SDU stream — reassembly (§1) is load-bearing here. There is no
message to request blocks by unordered hash set.

*Codec:* `lib/cardamom/protocol/block_fetch/codec.ex`; *fixtures:*
`test/fixtures/blocks/block-*.hex` (the first 20 real Preview blocks);
*tests:* `conway/block_fixtures_test.exs`, `conway/block_real_test.exs`.

## 6. Tx-submission2 (protocol 4)

```
[6]                              Init          (client, once, first)
[0, blocking, ackN, reqN]        RequestTxIds  ← SERVER sends (it pulls from us)
[1, [[txid, size]…]]             ReplyTxIds
[2, [txid…]]                     RequestTxs    ← server
[3, [tx…]]                       ReplyTxs
[4]                              Done
```

The protocol is **pull-based and asymmetric**: the *server* requests; a client
that has nothing to offer replies with empty lists. Note there is **no
removal/expiry message** — a mempool observer must infer tx exit (confirmed in
a block, or aged out) rather than being told.

**Encoding trap:** the id/tx lists MUST be **indefinite-length** CBOR arrays
(`0x9f … 0xff`). The reference codec rejects definite-length here, while most
CBOR libraries *emit* definite-length by default — we hand-roll these two
arrays. *Codec:* `lib/cardamom/protocol/tx_submission/codec.ex`.

## 7. Keep-alive (protocol 8)

```
[0, cookie]   KeepAlive          cookie: u16
[1, cookie]   KeepAliveResponse  (same cookie must round-trip)
[2]           Done
```

Send on a ~60s cadence and answer the peer's pings promptly; we measured a
connection with no keep-alive traffic being dropped at ~97s. This is the
cheapest protocol and effectively mandatory. *Client:*
`lib/cardamom/keep_alive/client.ex`.

## 8. Peer-sharing (protocol 10)

```
[0, amount]          ShareRequest (u8)
[1, [peerAddress…]]  SharePeers
[2]                  Done

peerAddress = [0, u32, port]                    IPv4
            | [1, u32, u32, u32, u32, port]     IPv6
```

Addresses are **packed integers, not strings**, and there is no hostname form
— a DNS-named peer cannot be shared. Treat received addresses as inert data to
record, not as instructions to dial. *Codec:*
`lib/cardamom/protocol/peer_sharing/codec.ex`.

## 9. Era envelopes — the numbering trap

Both chain-sync headers and block-fetch blocks arrive era-wrapped, but **the
two protocols number eras differently**. Byte-verified on the *same block*
(Preview block 0, a 15-field-header era-5-family block):

| Envelope | Bytes | Era tag |
|---|---|--:|
| chain-sync `RollForward` header | `83 02 82 04 d818…` | **4** |
| block-fetch `MsgBlock` block | `82 05 85 82 8f…` | **5** |

*(fixtures: `preview_rollforward.hex` vs `blocks/block-0.hex`)*

Similarly, current Conway-era chain-sync headers arrive tagged **5**
(10-field Praos headers; fixture `preview_rollforward_praos.hex` is one,
post-strip). Working hypothesis: block-fetch uses the HardFork era index
(Byron 0 … Babbage 5, Conway 6, Dijkstra 7) and chain-sync's header envelope
runs one lower for the Shelley family; we have not chased the *why* into the
consensus codecs. **Design consequence: do not build anything that trusts the
era tag as a cross-protocol era identity** — see §10 for what to do instead.
This is one axis of a wider tangle (era index ≠ on-chain protocol major
version ≠ negotiated N2N version — four version axes in total, none
aligned).

## 10. Headers: dispatch on shape, not on era tag

A Shelley-family header is `[header_body, kes_signature]`, and
`header_body`'s own CBOR array length says which decoder applies — the era
tag is unnecessary *and* unreliable (§9). Trusting it froze our body backfill
for an evening.

* **15 elements → TPraos** (Shelley…Babbage): TWO CertifiedVRF fields
  (nonce + leader), OCert (4 fields) and ProtVer (2) **inlined flat**:
  `[block_no, slot, prev_hash, issuer_vkey, vrf_vkey, vrf_eta, vrf_leader,
  body_size, body_hash, ocert_vkey, ocert_n, ocert_kes_period, ocert_sigma,
  proto_major, proto_minor]`
  — decoder `lib/cardamom/ledger/shelley/header.ex`, from
  `TPraos/BHeader.hs` (CBORGroup inlining is why it's flat).
* **10 elements → Praos** (Conway+): ONE combined CertifiedVRF, OCert and
  ProtVer **nested** as sub-arrays:
  `[block_no, slot, prev_hash, issuer_vkey, vrf_vkey, [vrf_out, vrf_proof],
  body_size, body_hash, [ocert…4], [major, minor]]`
  — decoder `lib/cardamom/ledger/praos/header.ex`, from consensus
  `Praos/Header.hs:176-216`.

Byron is structurally unrelated (`[tag, header]`) and is selected by era tag
0 only. *Dispatcher:* `lib/cardamom/ledger/header.ex`; *tests:*
`header_test.exs`, `praos/header_test.exs` (real fixtures both shapes).

**Hashing rule (chain-link critical):** a header's identity is
blake2b-256 of the **received** header bytes (the tag-24 payload), never a
re-encoding. `prev_hash` linkage only works under byte fidelity.

## 11. Blocks

```
block = [header, tx_bodies, tx_witness_sets, aux_data_map, invalid_transactions]
```

(era-wrapped per §9; strip `[era, …]` first.)

**Body-hash verification.** The header's `block_body_hash` commits to the
four non-header segments by a hash-of-four-hashes:

```
body_hash = blake2b256( blake2b256(tx_bodies_bytes)
                      <> blake2b256(tx_witness_sets_bytes)
                      <> blake2b256(aux_data_bytes)
                      <> blake2b256(invalid_transactions_bytes) )
```

over each segment's **original received bytes**. This algorithm exists in no
CDDL or prose — only `cardano-ledger`'s `hashAlonzoSegWits` (a byte-exact
spec gap, flagged in `network-specs.md` §3). Verify before trusting a fetched
body: anything can be attached to a valid header. *Implementation:*
`lib/cardamom/ledger/conway/block.ex` (`verify_body`); segment byte-spans are
carved element-by-element precisely so re-encoding never happens.

**invalid_transactions** (5th segment) lists tx *indices* that failed
phase-2 validation. Such a tx's normal inputs/outputs do NOT apply — its
collateral is consumed instead (§12). *Fixture:*
`preview_block_invalid_tx.hex`.

**Indefinite-length segments occur in the wild:** real Preview blocks exist
whose `tx_bodies` array is indefinite-length (`0x9f…0xff`) — a decoder
assuming definite-length silently miscounts. *Fixture:*
`preview_block_indefinite_txbodies.hex`.

## 12. Transaction bodies (Shelley family, upward-compatible)

A tx body is a CBOR map with integer keys; later eras add keys. The ones an
observer needs:

| Key | Field | Notes |
|--:|---|---|
| 0 | inputs | Conway wraps the list in **set tag #6.258**; earlier eras a bare array. Handle both. Each input `[txid32, ix]` |
| 1 | outputs | two shapes, see below |
| 2 | fee | uint |
| 4 | certificates | array of `[tag, …]`, §13 |
| 5 | withdrawals | map `rewardAddress(bytes) → coin` |
| 9 | mint | multiasset map |
| 13 | collateral inputs | consumed iff the tx is phase-2 invalid |
| 16 | collateral return | output; see the index rule below |
| 18 | reference inputs | read-only — NOT consumed |
| 19/20 | votes / proposals | governance (Conway) |
| 22 | donation | coin to treasury |

**Outputs, two shapes.** Legacy array `[address, value, ?datum_hash]`
(pre-Babbage and still emitted post-Babbage), or Babbage map
`{0: address, 1: value, 2: datum_option, 3: script_ref}` where
`datum_option = [0, hash] | [1, #6.24(datum)]`. **Both occur in the same
block stream** — decode by shape.

**Value, two shapes.** `coin` (bare uint, ADA-only) or
`[coin, {policy_id → {asset_name → amount}}]` (Mary+ multiasset).

**txid** = blake2b-256 of the tx body's **original bytes** (carve the span,
don't re-encode).

**Collateral-return index (subtle, corrupts UTxO tracking if wrong):** the
collateral-return output of a phase-2-invalid tx sits at
`TxIx = length(outputs)` — *after* the (unapplied) regular outputs — not at
index 0. Source: Babbage `Collateral.hs` (`txIxFromIntegral (length outputs)`);
no CDDL/prose states it. A dependent tx spending `(txid, 0)` of an invalid tx
must fail to resolve, not bind to the collateral change. *Test:*
`test/cardamom/store/collateral_return_index_test.exs` (found via a real
stuck Preview block).

*Decoder:* `lib/cardamom/ledger/conway/tx.ex` (all Shelley-family eras — the
body is upward-compatible; absent keys decode as absent).

## 13. Certificates (Conway, tx body key 4)

`[tag, …fields]`; credential sub-encoding `[0, keyhash28] | [1, scripthash28]`.

| Tag | Certificate | Tag | Certificate |
|--:|---|--:|---|
| 0 | stake registration (no deposit — deprecated) | 10 | stake+vote delegation |
| 1 | stake deregistration (no deposit — deprecated) | 11 | stake reg + pool delegation (deposit) |
| 2 | stake delegation (to pool) | 12 | vote reg + DRep delegation (deposit) |
| 3 | pool registration (9 param fields) | 13 | stake+vote reg+delegation (deposit) |
| 4 | pool retirement | 14 | committee hot-key auth |
| 7 | stake registration (explicit deposit) | 15 | committee resignation |
| 8 | stake deregistration (explicit refund) | 16 | DRep registration (deposit) |
| 9 | vote delegation (to DRep) | 17 | DRep deregistration (refund) |
| | | 18 | DRep update |

DRep sub-encoding: `[0,keyhash] | [1,scripthash] | [2] (abstain) |
[3] (no-confidence)`. Tags 5/6 are the retired MIR/genesis certs.
*Decoder:* `lib/cardamom/ledger/conway/cert.ex` (shapes from conway.cddl
lines 434–539; unknown tags decode to `{:unknown, tag}` — never crash on a
future cert).

## 14. Byron (era 0) — different in every respect

`[tag, content]` where tag 0 = epoch-boundary block (no txs), 1 = regular.
Regular body = `[txPayload, sscPayload, dlgPayload, updPayload]`; each
`TxAux = [tx, witness]`; `tx = [inputs, outputs, attributes]`; a `TxIn` is
`[0, #6.24(cbor([txid, index]))]` (a tag-24 *nested CBOR* indirection unique
to Byron); addresses are CRC-protected. txid = blake2b-256 of the tx's
original bytes. Full field-by-field mapping with `cardano-ledger` line
citations: `lib/cardamom/ledger/byron/body.ex`.

## 15. Gotchas, ranked by blood lost

1. **Reassembly** (§1) — messages span SDUs; SDUs pack messages. Both, routinely.
2. **Point hashes must be CBOR byte strings** (§4) — text-string hashes get
   you disconnected.
3. **Era-tag numbering differs per protocol** (§9) — never treat it as a
   cross-protocol era identity; dispatch headers on shape (§10).
4. **Hash received bytes, never re-encodings** (§10, §11, §12) — header
   hashes, body hashes, txids: all byte-exact.
5. **Collateral-return TxIx = length(outputs)** (§12).
6. **Indefinite vs definite arrays cut both ways** — tx-submission REQUIRES
   indefinite (§6); handshake REQUIRES definite maps (§3); real blocks may
   use either for `tx_bodies` (§11). Your CBOR library has a default; the
   wire doesn't care about your default.
7. **List-of-small-ints decodes as a charlist** in some CBOR libraries (§3).
8. **Conway sets arrive as tag #6.258** (§12) — unwrap before iterating.
9. **Keep-alive is de-facto mandatory** (§7) — ~97s to reaping without it.
10. **Two output shapes and two value shapes coexist** in one block (§12).
11. **tx-submission is server-driven** (§6) — and has no removal message; and
    a silent observer may simply not be *sent* much (peers gossip to nodes
    they expect to propagate).

## 16. Fixture index (conformance vectors)

| Fixture | Proves | Pinned by |
|---|---|---|
| `preview_rollforward.hex` | RollForward envelope, era tag 4, 15-field TPraos header | `ledger/header_test.exs`, `conway/header_real_test.exs` |
| `preview_rollforward_praos.hex` | 10-field Praos header (Conway; bare, post-strip) | `ledger/praos/header_test.exs`, `praos/validation_test.exs` |
| `preview_rollbackward.hex` | RollBackward shape | *captured, not yet test-pinned* |
| `blocks/block-0.hex … block-19.hex` | block-fetch era tag 5, block structure, body-hash verification, genesis-era decode | `conway/block_fixtures_test.exs` |
| `preview_block_1.hex`, `preview_block_13011.hex`, `preview_block_with_tx.hex` | real block + tx decode end-to-end | `conway/block_real_test.exs` |
| `preview_block_indefinite_txbodies.hex` | indefinite-length `tx_bodies` in the wild | `conway/block_real_test.exs` |
| `preview_block_invalid_tx.hex` | `invalid_transactions` + collateral path | `store/collateral_return_index_test.exs` |

`preview_capture.md` records how the live captures were taken.

---

*Safety note: everything here was learned against the Preview testnet, which
exists for this. An unproven implementation should never point at mainnet;
see `wire-protocol.md` for the full stance.*
