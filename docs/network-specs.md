# The specification landscape of the Cardano network layer

*An implementer's map — written from the experience of building Cardamom's
node-to-node client side from scratch. Last revised 2026-07-23.*

There is no single document from which one can implement the Cardano network
layer. The layer is specified by a **stack of artifacts of differing kind and
authority** — a machine-checked formal model, a prose specification, CDDL
grammars, configuration files, and (for several load-bearing details) the
Haskell reference implementation itself, confirmed against the live wire. This
document maps that stack: what each artifact is authoritative *for*, what it
deliberately leaves out, where artifacts disagree, and which details currently
have no specification other than code.

Companion documents: `wire-protocol.md` (byte-level details, findings, and
directives — the deep dive this document indexes), `architecture.md` (how
Cardamom itself is shaped).

**Scope.** "Network layer" here means the node-to-node (N2N) side: the
multiplexer and its SDU framing, the handshake, and the mini-protocols
(chain-sync, block-fetch, tx-submission, keep-alive, peer-sharing) — plus the
on-chain object encodings the network layer cannot avoid touching (headers and
blocks must be decoded and *hashed* byte-exactly to follow a chain).
Node-to-client protocols, the diffusion/peer-selection governor, and ledger
rules are out of scope.

---

## 1. The stack at a glance

| Layer | What you need to know | Primary artifact | Kind |
|---|---|---|---|
| Protocol behaviour | FSMs, agency, message sequencing, composition over one bearer | Agda ITree-CSP model (`agda-cardano-common`) | Formal, machine-checked |
| Protocol behaviour (prose) | Same ground, informally, plus protocol numbers and pipelining discussion | `ouroboros-network/docs/network-spec` | Prose (LaTeX) |
| Message encoding | CBOR grammar of every mini-protocol message | `ouroboros-network` CDDLs | Grammar |
| Transport framing | The 8-byte SDU header, segmentation, the mode bit | `network-spec/mux.tex` + `Network.Mux.Codec.hs` | Prose + code |
| Handshake & versioning | Version negotiation, `nodeToNodeVersionData`, network magic | handshake CDDLs + genesis config | Grammar + config |
| On-chain encodings | Header/block structure; the hashes that link the chain | `cardano-ledger` CDDL (Huddle-generated) + Haskell | Grammar + code |
| Operational limits | Per-state timeouts, size limits — what gets you disconnected | `network-spec/limits.tex` + protocol `Codec.hs` files | Prose + code |
| Environment | Network magic values, bootstrap relays, era history | genesis/topology JSON per network | Config |

A useful epistemic ordering when artifacts disagree, learned the hard way:
**the live wire > the Haskell implementation > the CDDL > the prose > any
model** — with every disagreement being a reportable finding, not just a local
fix. (The formal model is listed last not because it is least trustworthy but
because it deliberately abstracts most; within its scope it is the *most*
precise statement that exists.)

---

## 2. The artifacts in detail

### 2.1 The formal behavioural model — Agda ITree-CSP

*upstream:* `github.com/input-output-hk/agda-cardano-common`, branch
`kangfeng/itree-csp`, under `src/ITree-CSP/CSP/Examples/Cardano_network/`
*(read at ee1f4a2, 2026-07-06)*

The successor to the earlier CSPm/FDR model
(`mini_protocols_KA_BF_CS_Tx_20260514.csp`): the N2N mini-protocols —
KeepAlive, ChainSync, BlockFetch, TxSubmission2, and the Leios protocols
(LeiosNotify/LeiosFetch) — formalised as CSP-style peer processes over process
trees, composed over a shared network medium, **with machine-checked proofs**:
deadlock-freedom, divergence-freedom, and the multiplexer correctness contract
(`Network ≈FD CopySpec` — the mux must behave as one independent lossless FIFO
per mini-protocol).

**Authoritative for:** the state machines (e.g. chain-sync's
`stIdle → stCanAwait → stMustReply` with the `AwaitReply` two-step, and
`stIntersect`), agency (who may send in which state), the message *sets*, and
the composition/mux contract. The peers are *API-driven*: protocol decisions
enter via explicit `api…` control events, cleanly separating the protocol FSM
(pure reaction) from the policy that drives it — a structure an implementation
does well to mirror.

**Deliberately absent:** concrete encodings (payloads are abstract), the
handshake (not modelled at all), wire protocol *numbers* (protocols are named,
not numbered), all timing/timeouts (`Time` is an inert placeholder), and SDU
segmentation. Every one of these must come from the artifacts below.

Key modules: `ChainSync.agda` (`CSState`, `clientStep`), `Data.agda` (message
datatypes), `Base.agda` (protocol identities), `Network.agda`
(`Network`/`CopySpec`), `NetworkPar.agda` (whole-node composition), the
`*Thm.agda` files (the proofs). The README's reading order is good.

### 2.2 The prose specification — `network-spec`

*upstream:* `ouroboros-network/docs/network-spec/*.tex` *(read at d842a23, 2026-05-22)*

The official informal specification: `miniprotocols.tex` (protocol
descriptions, state tables, **the protocol number tables**), `mux.tex` (the
SDU wire format, correctly stating the mode bit: 0 = initiator, 1 =
responder), `limits.tex` (timeouts and size limits per protocol state),
`connection-manager.tex`, `architecture.tex`. Sibling directory
`network-design` holds the design-rationale document.

**Honest experience report:** we initially built the SDU codec from the mux
*source* believing no prose spec existed, and only later found `mux.tex` — the
document is correct and would have sufficed. A from-scratch implementer's
discovery path does not reliably lead here; treat this mapping document as the
index that was missing. The prose spec is the right place to *start*, and the
CDDL + code the places to *verify*.

### 2.3 Message encodings — the `ouroboros-network` CDDLs

*upstream path (current layout):*
`cardano-diffusion/protocols/cddl/specs/*.cddl` — note this moved recently
(was `ouroboros-network-protocols/...`); expect further drift.

One grammar file per protocol; each message is a CBOR array with a leading
integer tag. Used by Cardamom, one codec module per file:

| CDDL | Protocol (N2N number) |
|---|---|
| `chain-sync.cddl` | chain-sync (2) — tags 0–7, maps 1:1 to the formal message set |
| `block-fetch.cddl` | block-fetch (3) |
| `tx-submission2.cddl` | tx-submission (4) |
| `keep-alive.cddl` | keep-alive (8) |
| `peer-sharing-v14.cddl` | peer-sharing (10) |
| `handshake-node-to-node-v14.cddl` + `node-to-node-version-data-v14.cddl` | handshake (0) |
| `network.base.cddl` | shared primitives |

Handshake version data (v14):
`[networkMagic : word32, initiatorOnlyDiffusionMode : bool, peerSharing : 0..1, query : bool]`.
`initiatorOnlyDiffusionMode` is a first-class "I only initiate, won't serve"
declaration — a pure observer states its role in the handshake itself.

**Caveats.** (a) The network-magic *value* is not in the CDDL (it is typed
`word32` only) — it comes from the target network's genesis configuration.
(b) Version files churn: v11–13 are in `obsolete/`, and a
`node-to-node-version-data-v16.cddl` now exists — an implementation should
verify what the live network actually negotiates rather than assuming.
(c) These grammars say nothing about *when* a message may be sent — sequencing
and agency live in the formal model / prose spec. Both halves are needed.

### 2.4 Transport framing — the mux SDU

*spec:* `network-spec/mux.tex` §Wire Format; *reference:*
`network-mux/src/Network/Mux/{Codec,Types,Bearer}.hs`; *byte-level write-up
with worked details:* `wire-protocol.md` §"SDU header".

8-byte big-endian header — 32-bit transmission timestamp (µs, monotonic,
wraps), 1 mode bit + 15-bit mini-protocol number, 16-bit payload length —
then payload. Logical messages larger than one SDU are split across SDUs and
**must be reassembled before CBOR decoding** (block-fetch bodies routinely
span many SDUs). The standard socket bearer caps SDU payloads at 12,288 bytes
(`Bearer.hs`), below the wire format's 2¹⁶−1 maximum.

**Known documentation defect:** the prose comment inside `Codec.hs` (lines
29–32) states the mode bit backwards ("1 = initiator"). The spec (`mux.tex`)
and the code's behaviour agree: **0 = initiator, 1 = responder**. Trust the
code and `mux.tex`; the source comment should be fixed upstream.

### 2.5 On-chain encodings the network layer must handle — `cardano-ledger`

*upstream:* `intersectmbo/cardano-ledger`,
`eras/conway/impl/cddl/data/conway.cddl` *(read at cd8b7fab8, 2026-06-03)*

Chain-following forces byte-exact handling of on-chain objects: verifying
`prevHash` links means hashing the *received header bytes* (never a
re-encoding), and verifying a body against its header means recomputing the
body hash. The CDDL gives the structure (header shape, transaction body keys,
`hash32 = bytes .size 32`, set tag #6.258, value/multiasset forms). Three
caveats matter:

1. **The `.cddl` is generated.** It is rendered from the Huddle DSL
   (`HuddleSpec.hs`); Huddle is the upstream truth, and design history lives
   there, not in the rendered file.
2. **The grammar is necessary but not sufficient.** Load-bearing constraints
   appear as prose *comments* the grammar cannot express (segment lists must
   agree in length; invalid-transaction indices must be in range). Enforcing
   only the CDDL under-validates.
3. **Some algorithms exist only as Haskell** — see §3.

Canonical/deterministic CBOR is assumed throughout: one logical object, one
byte form, or hashes do not agree. A general-purpose CBOR library's strictness
must be *verified*, not assumed (see `wire-protocol.md`'s strict-CDDL
directive and the real network-split incident that motivates it).

### 2.6 Operational behaviour — what disconnects a peer

*spec:* `network-spec/limits.tex`; *reference:*
`ouroboros-network/protocols/lib/.../Protocol/*/Codec.hs`; *confirmed live.*

The real node enforces three axes, and violating any closes the connection:
(1) **agency-respecting decode** — a message in a state where the sender lacks
agency, a wrong arity, or an unknown tag is a protocol violation; (2)
**per-state size limits**; (3) **per-state timeouts** — e.g. chain-sync
`StMustReply` allows 601–911s (randomised) after `AwaitReply`; keep-alive
expects traffic on a ~60s cadence, and an idle connection is reaped (observed:
dropped at 97s without keep-alives). A test peer for a new implementation
should *enforce* these axes, so passing against the fake predicts surviving
the real network.

### 2.7 Environment / configuration

*per-network genesis + topology files* (e.g.
`book.world.dev.cardano.org/environments/<network>/`).

Supplies the facts no grammar carries: **network magic** (Preview = 2,
mainnet = 764824073 — a wrong value is an instant handshake rejection),
bootstrap relay addresses, system start, slot length, epoch length, and the
security parameter *k*. Also CIP-19 for address structure when decoding
outputs.

### 2.8 The wire itself

Some facts were obtainable only by connecting to a real relay (Preview
testnet — never mainnet — for all experimental traffic; see
`wire-protocol.md` on safety):

* **Era-wrapping envelopes and their numbering.** Chain-sync RollForward
  headers arrive as `[era, #6.24(header-bytes)]`; block-fetch blocks as
  `[era, block]` — and the era *numbering differs between contexts* (one of
  at least four non-aligned version axes in Cardano: on-chain protocol major,
  era name, wire era tags, library versions).
* **Header-shape dispatch.** The era tag alone cannot be trusted for header
  decoding; the reliable dispatch is the header body's own arity (15 fields
  through Babbage, 10 from Conway), with body-hash verification as the
  non-foolable check.
* **Tolerance is asymmetric.** The relay tolerates slow consumers
  indefinitely (chain-sync is pull-based) but disconnects on malformed
  resumption (a bad FindIntersect got us dropped).
* Sustained throughput characteristics (headers stream far faster than
  bodies; both are fine — chain-sync and block-fetch are independent
  protocols and the gap closes at the tip).

---

## 3. The gaps: needed, but specified nowhere (or wrongly)

Each of these cost real reverse-engineering time; each is a candidate for
upstream promotion into CDDL or prose.

**Code is the only spec (byte-exact algorithms):**
1. **Block body hash** — the header's `block_body_hash` commitment is a
   hash-of-four-hashes over the four "segwit" segments
   (`hashAlonzoSegWits`); no CDDL or prose states the algorithm.
2. **Operational-certificate signable bytes** — the exact byte concatenation
   an opcert's cold-key signature covers (`OCert.hs`,
   `getSignableRepresentation`).
3. **Genesis UTxO derivation** — pseudo-transaction-input construction for
   initial funds (`Shelley/Genesis.hs`), and the Byron variant.
4. **Collateral-return output index** — `TxIx = length(outputs)`, not 0
   (Babbage `Collateral.hs`); assuming 0 corrupts UTxO tracking on every
   phase-2-invalid transaction.
5. **All of Byron** — block/body/tx encodings reconstructed from the decoders
   (`Block.hs`, `Body.hs`, `TxAux.hs`, `Tx.hs`, CRC-protected addresses).

**Documented wrongly or inconsistently:**
6. The `Codec.hs` mode-bit comment contradicts both the code and `mux.tex`
   (§2.4).
7. The CSPm-era model carried a single `Point` in `FindIntersect` where the
   wire carries a list — *fixed* in the Agda successor (`List Point`), noted
   here for anyone still holding the CSPm file.

**No formal treatment exists:**
8. **The handshake** — the first and most failure-prone exchange on every
   connection has CDDL and prose but no behavioural model.
9. **Timing** — all timeout behaviour (a disconnection cause, §2.6) is outside
   the formal model.
10. **Egress scheduling** — the fairness discipline between protocols sharing
    a bearer is described in prose only; `CopySpec` (per-protocol FIFO
    correctness) is proved, but inter-protocol fairness is not modelled.

**Cross-cutting:**
11. **The version-axes tangle** — era numbers, protocol-major versions, wire
    era tags, and negotiated N2N versions do not align and are nowhere laid
    side-by-side; every implementer builds this table themselves.
12. **Findability** — several artifacts above are correct but effectively
    undiscoverable from each other (nothing links the CDDLs to `network-spec`
    to the formal model). The absence of an index like this document is
    itself the meta-gap.

---

## 4. Minimum viable client (first contact)

The smallest artifact set that gets an implementation talking to a relay:

1. **Handshake** (protocol 0): `handshake-node-to-node-v14.cddl` + version
   data + network magic from genesis config. Propose v14+; declare
   `initiatorOnlyDiffusionMode = true` if observing.
2. **Keep-alive** (protocol 8): `keep-alive.cddl`; answer pings promptly or
   be reaped (§2.6, §2.8).
3. **Chain-sync client** (protocol 2): FSM from the Agda model
   (`ChainSync.agda`) or `miniprotocols.tex`; encoding from
   `chain-sync.cddl`; era envelopes from §2.8; header hashing from §2.5.

All of it framed in SDUs per §2.4, all of it strict per the CDDL directive.
Block-fetch, tx-submission, and peer-sharing are additive after that.
