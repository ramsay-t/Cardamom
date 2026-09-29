# The specification landscape of the Cardano network layer

*An implementer's map — written from the experience of building Cardamom's
node-to-node client side from scratch. Links verified and pinned 2026-09-29.*

There is no single document from which one can implement the Cardano network
layer. The layer is specified by a **stack of artifacts of differing kind and
authority** — a machine-checked formal model, a prose specification, CDDL
grammars, configuration files, and (for several byte-exact details) the
Haskell reference implementation itself, confirmed against the live wire. This
document maps that stack: where each artifact lives, what it is authoritative
*for*, what it deliberately leaves out, where artifacts disagree, and which
details currently have no specification other than code.

**How to read the links.** Every upstream citation is given twice: a
*permalink* pinned to the commit at which we verified the claim (stable, will
not rot, may fall behind), and where useful a *tracking* link to the branch
head (current, may move). Line anchors are on the permalinks only. In-repo
citations (`lib/…`, `test/…`) are relative links into this repository.

Companion documents in this repository:
[`WIRE.md`](WIRE.md) (the wire byte by byte — every claim pinned to a captured
fixture and a test), [`wire-protocol.md`](wire-protocol.md) (the working notes
this document was distilled from), [`architecture.md`](architecture.md) (how
Cardamom itself is shaped).

**Scope.** "Network layer" here means the node-to-node (N2N) side: the
multiplexer and its SDU framing, the handshake, and the mini-protocols
(chain-sync, block-fetch, tx-submission, keep-alive, peer-sharing) — plus the
on-chain object encodings the network layer cannot avoid touching (headers and
blocks must be decoded and *hashed* byte-exactly to follow a chain).
Node-to-client protocols, the diffusion/peer-selection governor, and ledger
rules are out of scope.

---

## 0. The repositories, in one place

| Repository | What it holds for us | Tracking link | Pinned at (verified 2026-09-29) |
|---|---|---|---|
| `IntersectMBO/ouroboros-network` | prose spec (`docs/network-spec`), design doc, CDDLs, mux source, protocol codecs | [main](https://github.com/IntersectMBO/ouroboros-network/tree/main) | [`a3d8017e7`](https://github.com/IntersectMBO/ouroboros-network/tree/a3d8017e798b225055aaf9118ad062fe58bc650f) (2026-09-15) |
| `IntersectMBO/ouroboros-consensus` | header decoders, the HardFork block envelope, Praos VRF derivations | [main](https://github.com/IntersectMBO/ouroboros-consensus/tree/main) | [`73fa2da6a`](https://github.com/IntersectMBO/ouroboros-consensus/tree/73fa2da6a42c273ae723a8830eb7159ab2b6b073) (2026-06-18) |
| `IntersectMBO/cardano-ledger` | on-chain CDDL (Huddle-generated), body-hash, opcert, Byron, collateral rules | [master](https://github.com/IntersectMBO/cardano-ledger/tree/master) | [`3118136df`](https://github.com/IntersectMBO/cardano-ledger/tree/3118136df7b5ccff3ca2f06245ed91d81f50b994) (2026-09-29) |
| `input-output-hk/agda-cardano-common`, branch `kangfeng/itree-csp` | the formal behavioural model of the mini-protocols (Agda, ITree-CSP) | [branch](https://github.com/input-output-hk/agda-cardano-common/tree/kangfeng/itree-csp) | read at [`ee1f4a2`](https://github.com/input-output-hk/agda-cardano-common/tree/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14) (2026-07-06); tip [`9a40d1d`](https://github.com/input-output-hk/agda-cardano-common/tree/9a40d1de330f376c3a102e7c9f1282f4fa830a7e) (2026-09-28) |

Rendered artefacts (no clone needed):

* **Network spec (PDF):** <https://ouroboros-network.cardano.intersectmbo.org/pdfs/network-spec/network-spec.pdf>
* **Network design (PDF):** <https://ouroboros-network.cardano.intersectmbo.org/pdfs/network-design/network-design.pdf>
* **ouroboros-network Haddocks:** <https://ouroboros-network.cardano.intersectmbo.org/>
* **Ledger specs and CDDL site:** <https://cardano-ledger.cardano.intersectmbo.org/>
* **Preview testnet environment files:** [`config.json`](https://book.world.dev.cardano.org/environments/preview/config.json), [`shelley-genesis.json`](https://book.world.dev.cardano.org/environments/preview/shelley-genesis.json), [`topology.json`](https://book.world.dev.cardano.org/environments/preview/topology.json) under `book.world.dev.cardano.org/environments/preview/` (the directory itself does not list)
* **CIP-19 (address structure):** <https://cips.cardano.org/cip/CIP-19>

---

## 1. The stack at a glance

| Layer | What you need to know | Primary artifact | Kind |
|---|---|---|---|
| Protocol behaviour | FSMs, agency, message sequencing, composition over one bearer | Agda ITree-CSP model (§2.1) | Formal, machine-checked |
| Protocol behaviour (prose) | Same ground, informally, plus protocol numbers and pipelining discussion | `network-spec` LaTeX / PDF (§2.2) | Prose |
| Message encoding | CBOR grammar of every mini-protocol message | `ouroboros-network` CDDLs (§2.3) | Grammar |
| Transport framing | The 8-byte SDU header, segmentation, the mode bit | `mux.tex` + `Network.Mux.Codec` (§2.4) | Prose + code |
| Handshake & versioning | Version negotiation, `nodeToNodeVersionData`, network magic | handshake CDDLs + genesis config (§2.3, §2.7) | Grammar + config |
| On-chain encodings | Header/block structure; the hashes that link the chain | `cardano-ledger` CDDL + Haskell (§2.5) | Grammar + code |
| Operational limits | Per-state timeouts, size limits — what gets you disconnected | `limits.tex` + protocol `Codec.hs` files (§2.6) | Prose + code |
| Environment | Network magic values, bootstrap relays, era history | genesis/topology JSON per network (§2.7) | Config |

A useful epistemic ordering when artifacts disagree, learned the hard way:
**the live wire > the Haskell implementation > the CDDL > the prose > any
model** — with every disagreement being a reportable finding, not just a local
fix. (The formal model is listed last not because it is least trustworthy but
because it deliberately abstracts most; within its scope it is the *most*
precise statement that exists.)

---

## 2. The artifacts in detail

### 2.1 The formal behavioural model — Agda ITree-CSP

* Directory (tracking): [`src/ITree-CSP/CSP/Examples/Cardano_network/`](https://github.com/input-output-hk/agda-cardano-common/tree/kangfeng/itree-csp/src/ITree-CSP/CSP/Examples/Cardano_network)
* Start here: [`README.md`](https://github.com/input-output-hk/agda-cardano-common/blob/kangfeng/itree-csp/src/ITree-CSP/CSP/Examples/Cardano_network/README.md) (module map and reading order) and [`mini-protocols.md`](https://github.com/input-output-hk/agda-cardano-common/blob/kangfeng/itree-csp/src/ITree-CSP/CSP/Examples/Cardano_network/mini-protocols.md) (per-protocol summary: what is modelled and what is proved), written for a reader who knows the `ouroboros-network` specs and CSP but not the repository.
* Pinned at the commit we transcribed from (`ee1f4a2`, 2026-07-06): [`ChainSync.agda`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/ChainSync.agda#L135-L140) (`CSState`, the state set; [`clientStep`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/ChainSync.agda#L175-L245) is the client FSM), [`Data.agda`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/Data.agda) (message datatypes), [`Base.agda`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/Base.agda) (protocol identities), [`Network.agda`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/Network.agda) (`Network` and `CopySpec`), [`NetworkPar.agda`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/NetworkPar.agda) (whole-node composition), and the proofs [`NetworkDeadlockFreeThm.agda`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/NetworkDeadlockFreeThm.agda), [`NetworkDivergenceFreeThm.agda`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/NetworkDivergenceFreeThm.agda), [`NetworkRefinement.agda`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/NetworkRefinement.agda).

The successor to the earlier CSPm/FDR model
(`mini_protocols_KA_BF_CS_Tx_20260514.csp`, no longer available): the N2N
mini-protocols — KeepAlive, ChainSync, BlockFetch, TxSubmission2, and the
Leios protocols (LeiosNotify/LeiosFetch) — formalised as CSP-style peer
processes over process trees, composed over a shared network medium, **with
machine-checked proofs**: deadlock-freedom, divergence-freedom, and the
multiplexer correctness contract (`Network ≈FD CopySpec` — the mux must
behave as one independent lossless FIFO per mini-protocol instance).

**Authoritative for:** the state machines (e.g. chain-sync's
`stIdle → stCanAwait → stMustReply` with the `AwaitReply` two-step, and
`stIntersect`), agency (who may send in which state), the message *sets*, and
the composition/mux contract. The peers are *API-driven*: protocol decisions
enter via explicit `api…` control events, cleanly separating the protocol FSM
(pure reaction) from the policy that drives it — a structure an implementation
does well to mirror (see the driver-factoring rules in
[`wire-protocol.md`](wire-protocol.md#csp-structural-fidelity--house-rules)).

**Deliberately absent:** concrete encodings (payloads are abstract), the
handshake (not modelled at all), wire protocol *numbers* (protocols are named,
not numbered — only the Leios ids 18/19 appear, in a comment), all
timing/timeouts, and SDU segmentation. Every one of these must come from the
artifacts below.

**The branch is active and has moved since we read it** (tip `9a40d1d`,
2026-09-28): connections are now indexed by `(Link, Dir)` rather than a
per-protocol `Conn`, so `clientStep` takes `Link → Dir → CSState`; the theorem
files have moved under `NetworkVerification/` and the scenarios under
`FourNode/` and `Parametric/`; a second, `leios-prototype`-aligned model of
each Leios protocol coexists with the CIP-draft one. The state names and the
chain-sync FSM structure we transcribed are unchanged. Re-pin to the tip
before citing line numbers in new work.

### 2.2 The prose specification — `network-spec`

* Rendered PDF: <https://ouroboros-network.cardano.intersectmbo.org/pdfs/network-spec/network-spec.pdf>
* Source (tracking): [`docs/network-spec/`](https://github.com/IntersectMBO/ouroboros-network/tree/main/docs/network-spec); pinned: [`miniprotocols.tex`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/miniprotocols.tex), [`mux.tex`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/mux.tex), [`limits.tex`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/limits.tex), [`connection-manager.tex`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/connection-manager.tex), [`architecture.tex`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/architecture.tex)
* Design rationale (sibling): [`docs/network-design/`](https://github.com/IntersectMBO/ouroboros-network/tree/main/docs/network-design), rendered at <https://ouroboros-network.cardano.intersectmbo.org/pdfs/network-design/network-design.pdf>

The official informal specification: `miniprotocols.tex` (protocol
descriptions, state tables, and the **protocol-number tables** — each
protocol entry also links its Haskell `Type.hs` and Haddock page), `mux.tex`
(the SDU wire format, correctly stating the mode bit: 0 = initiator, 1 =
responder — [`mux.tex` L98–99](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/mux.tex#L98-L99) — and a
[second protocol-number table at §"Node-to-node and node-to-client protocol numbers"](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/mux.tex#L147)),
`limits.tex` ([Timeouts](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/limits.tex#L3), [Space limits](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/limits.tex#L51)).

**Honest experience report:** we initially built the SDU codec from the mux
*source* believing no prose spec existed, and only later found `mux.tex` —
the document is correct and would have sufficed. A from-scratch implementer's
discovery path does not reliably lead here; treat this mapping document as the
index that was missing. The prose spec is the right place to *start*, and the
CDDL + code the places to *verify*.

### 2.3 Message encodings — the `ouroboros-network` CDDLs

* Directory (tracking): [`cardano-diffusion/protocols/cddl/specs/`](https://github.com/IntersectMBO/ouroboros-network/tree/main/cardano-diffusion/protocols/cddl/specs) — note this has moved at least once (it was under `ouroboros-network-protocols/`); if the tracking link is dead, search the repository for `chain-sync.cddl`.

One grammar file per protocol; each message is a CBOR array with a leading
integer tag. Used by Cardamom, one codec module per file:

| CDDL (pinned) | Protocol (N2N number) | Our codec |
|---|---|---|
| [`chain-sync.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/chain-sync.cddl) | chain-sync (2) — tags 0–7, maps 1:1 to the formal message set | [`protocol/chain_sync/codec.ex`](../lib/cardamom/protocol/chain_sync/codec.ex) |
| [`block-fetch.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/block-fetch.cddl) | block-fetch (3) | [`protocol/block_fetch/codec.ex`](../lib/cardamom/protocol/block_fetch/codec.ex) |
| [`tx-submission2.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/tx-submission2.cddl) | tx-submission (4) | [`protocol/tx_submission/codec.ex`](../lib/cardamom/protocol/tx_submission/codec.ex) |
| [`keep-alive.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/keep-alive.cddl) | keep-alive (8) | [`keep_alive/client.ex`](../lib/cardamom/keep_alive/client.ex) |
| [`peer-sharing-v14.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/peer-sharing-v14.cddl) | peer-sharing (10) | [`protocol/peer_sharing/codec.ex`](../lib/cardamom/protocol/peer_sharing/codec.ex) |
| [`handshake-node-to-node-v14.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/handshake-node-to-node-v14.cddl) + [`node-to-node-version-data-v14.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/node-to-node-version-data-v14.cddl) / [`…-v16.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/node-to-node-version-data-v16.cddl) | handshake (0) | [`protocol/handshake/codec.ex`](../lib/cardamom/protocol/handshake/codec.ex) |
| [`network.base.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/network.base.cddl) | shared primitives | — |

Handshake version data, v14 and v15:
`[networkMagic : word32, initiatorOnlyDiffusionMode : bool, peerSharing : 0..1, query : bool]`.
From **v16** a fifth field is appended, `perasSupport : bool`
([`node-to-node-version-data-v16.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/node-to-node-version-data-v16.cddl)),
and the handshake grammar dispatches on version range
([`handshake-node-to-node-v14.cddl` L11–18](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/handshake-node-to-node-v14.cddl#L11-L18)).
`initiatorOnlyDiffusionMode` is a first-class "I only initiate, won't serve"
declaration — a pure observer states its role in the handshake itself.
Cardamom proposes v14 only
([`handshake/client.ex`](../lib/cardamom/protocol/handshake/client.ex)) and
Preview relays accept it.

**Caveats.** (a) The network-magic *value* is not in the CDDL (it is typed
`word32` only) — it comes from the target network's genesis configuration
(§2.7). (b) Version files churn: v11–13 are in `obsolete/`; an implementation
should verify what the live network actually negotiates rather than assuming.
(c) Two grammars carry **codec-only constraints as comments**: the handshake
version table must be a *definite*-length map
([L16](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/handshake-node-to-node-v14.cddl#L16)),
and tx-submission's id/tx lists must be *indefinite*-length
([L28](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/tx-submission2.cddl#L28), [L32](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/tx-submission2.cddl#L32)).
CDDL cannot express either; miss the comment and the reference codec rejects
you. (d) These grammars say nothing about *when* a message may be sent —
sequencing and agency live in the formal model / prose spec. Both halves are
needed. (e) An [`object-diffusion.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/object-diffusion.cddl)
has appeared (a generic object-diffusion mini-protocol); we have not needed it
and have not read it.

### 2.4 Transport framing — the mux SDU

* Spec: [`mux.tex` §Wire Format](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/mux.tex#L60)
* Reference: [`Network/Mux/Codec.hs`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/network-mux/src/Network/Mux/Codec.hs), [`Types.hs`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/network-mux/src/Network/Mux/Types.hs), [`Bearer.hs`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/network-mux/src/Network/Mux/Bearer.hs#L86)
* Our implementation: [`mux/sdu.ex`](../lib/cardamom/mux/sdu.ex) (codec), [`mux/reassembler.ex`](../lib/cardamom/mux/reassembler.ex) (message reassembly); byte-level write-up in [`WIRE.md` §1](WIRE.md#1-transport-the-mux-sdu).

8-byte big-endian header — 32-bit transmission timestamp (µs, monotonic,
wraps), 1 mode bit + 15-bit mini-protocol number, 16-bit payload length —
then payload. Logical messages larger than one SDU are split across SDUs and
**must be reassembled before CBOR decoding** (block-fetch bodies routinely
span many SDUs). The standard socket bearer caps SDU payloads at 12,288 bytes
([`Bearer.hs` L86](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/network-mux/src/Network/Mux/Bearer.hs#L86)),
below the wire format's 2¹⁶−1 maximum.

**Known documentation defect (still present at `a3d8017e7`):** the comment
inside `Codec.hs`
([L32–33](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/network-mux/src/Network/Mux/Codec.hs#L32-L33))
states the mode bit backwards ("1 = initiator"). The code
([L51–52](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/network-mux/src/Network/Mux/Codec.hs#L51-L52), [L87–88](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/network-mux/src/Network/Mux/Codec.hs#L87-L88))
and `mux.tex` agree: **0 = initiator, 1 = responder**. Trust the code and
`mux.tex`; the source comment should be fixed upstream.

### 2.5 On-chain encodings the network layer must handle — `cardano-ledger`

* Rendered specs and CDDL: <https://cardano-ledger.cardano.intersectmbo.org/>
* Conway CDDL (pinned): [`eras/conway/impl/cddl/data/conway.cddl`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/conway/impl/cddl/data/conway.cddl) — [`block`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/conway/impl/cddl/data/conway.cddl#L8), [`header`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/conway/impl/cddl/data/conway.cddl#L61), [`header_body`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/conway/impl/cddl/data/conway.cddl#L63), [`hash32`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/conway/impl/cddl/data/conway.cddl#L80)
* Its source of truth, the Huddle DSL: [`Cardano/Ledger/Conway/HuddleSpec.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/conway/impl/cddl/lib/Cardano/Ledger/Conway/HuddleSpec.hs) (one per era under `eras/*/impl/cddl/lib/`)

Chain-following forces byte-exact handling of on-chain objects: verifying
`prevHash` links means hashing the *received header bytes* (never a
re-encoding), and verifying a body against its header means recomputing the
body hash. The CDDL gives the structure (header shape, transaction body keys,
`hash32 = bytes .size 32`, set tag #6.258, value/multiasset forms). Three
caveats matter:

1. **The `.cddl` is generated.** It is rendered from the Huddle DSL; Huddle
   is the upstream truth, and design history lives there, not in the rendered
   file.
2. **The grammar is necessary but not sufficient.** Constraints that decide
   validity appear as prose *comments* the grammar cannot express (segment lists must
   agree in length; invalid-transaction indices must be in range). Enforcing
   only the CDDL under-validates.
3. **Some algorithms exist only as Haskell** — see §3.

Canonical/deterministic CBOR is assumed throughout: one logical object, one
byte form, or hashes do not agree. A general-purpose CBOR library's strictness
must be *verified*, not assumed (see the strict-CDDL directive in
[`wire-protocol.md`](wire-protocol.md#directive-parse-the-cddl-and-enforce-it--strict-never-coerce)
and the real network-split incident that motivates it).

### 2.6 Operational behaviour — what disconnects a peer

* Spec: [`limits.tex`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/limits.tex)
* Reference: the per-protocol codecs under [`ouroboros-network/protocols/lib/Ouroboros/Network/Protocol/`](https://github.com/IntersectMBO/ouroboros-network/tree/a3d8017e798b225055aaf9118ad062fe58bc650f/ouroboros-network/protocols/lib/Ouroboros/Network/Protocol) (each `*/Codec.hs` decodes on `(state, arity, tag)` and fails otherwise)
* Confirmed live against the Preview bootstrap relay.

The real node enforces three axes, and violating any closes the connection:
(1) **agency-respecting decode** — a message in a state where the sender lacks
agency, a wrong arity, or an unknown tag is a protocol violation; (2)
**per-state size limits**; (3) **per-state timeouts** — e.g. chain-sync
`StMustReply` allows 601–911s (randomised) after `AwaitReply`; keep-alive
expects traffic on a ~60s cadence, and an idle connection is reaped (observed:
dropped at 97s without keep-alives). A test peer for a new implementation
should *enforce* these axes, so passing against the fake predicts surviving
the real network (ours: [`sim_peer.ex`](../lib/cardamom/sim_peer.ex)).

### 2.7 Environment / configuration

* Preview: `book.world.dev.cardano.org/environments/preview/` (no directory listing; fetch the files directly) — [`config.json`](https://book.world.dev.cardano.org/environments/preview/config.json), [`shelley-genesis.json`](https://book.world.dev.cardano.org/environments/preview/shelley-genesis.json) (network magic, system start, slot/epoch lengths, *k*), [`topology.json`](https://book.world.dev.cardano.org/environments/preview/topology.json) (bootstrap relay: `preview-node.play.dev.cardano.org:3001`)
* Other networks are siblings under `environments/` (`preprod`, `mainnet`).
* Address structure: [CIP-19](https://cips.cardano.org/cip/CIP-19).

Supplies the facts no grammar carries: **network magic** (Preview = 2,
mainnet = 764824073 — a wrong value is an instant handshake rejection),
bootstrap relay addresses, system start, slot length, epoch length, and the
security parameter *k*.

### 2.8 The wire itself

Some facts were obtainable only by connecting to a real relay (Preview
testnet — never mainnet — for all experimental traffic; see
[`wire-protocol.md`](wire-protocol.md#why-preview-not-mainnet-safety--ethics-not-just-convenience)
on safety). Each is written up with its captured fixture in
[`WIRE.md`](WIRE.md); the fixtures themselves are in
[`test/fixtures/`](../test/fixtures/) and are reusable as conformance
vectors by any implementation.

* **Era-wrapping envelopes and their numbering.** Chain-sync RollForward
  headers arrive as `[era, #6.24(header-bytes)]`; block-fetch blocks as
  `[era, block]` — and the era *numbering differs between contexts*. The
  block envelope is the HardFork combinator's on-disk encoding, in which
  Byron occupies two tags (EBB / regular) so every later era is one higher
  than in the header envelope
  ([`Cardano/Node.hs`, `SerialiseHFC` instance and the comment above it](https://github.com/IntersectMBO/ouroboros-consensus/blob/73fa2da6a42c273ae723a8830eb7159ab2b6b073/ouroboros-consensus-cardano/src/ouroboros-consensus-cardano/Ouroboros/Consensus/Cardano/Node.hs#L136-L214)).
  This is one of at least four non-aligned version axes in Cardano: on-chain
  protocol major, era name, wire era tags, library versions. An independent
  implementation (TSUNAGI, in Zig) was bitten by exactly this — see
  [their incident record](https://tsunagi.tech/kintsugi/#frontier-1-era-envelope-inc-001-verified-closed).
* **Header-shape dispatch.** The era tag alone cannot be trusted for header
  decoding; the reliable dispatch is the header body's own arity (15 fields
  for TPraos, Shelley through Alonzo; 10 for Praos, Babbage onward), with
  body-hash verification as the non-foolable check. Decoders:
  [`TPraos/BHeader.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/libs/cardano-protocol-tpraos/src/Cardano/Protocol/TPraos/BHeader.hs),
  [`Praos/Header.hs`](https://github.com/IntersectMBO/ouroboros-consensus/blob/73fa2da6a42c273ae723a8830eb7159ab2b6b073/ouroboros-consensus-protocol/src/ouroboros-consensus-protocol/Ouroboros/Consensus/Protocol/Praos/Header.hs#L203).
* **Tolerance is asymmetric.** The relay tolerates slow consumers
  indefinitely (chain-sync is pull-based) but disconnects on malformed
  resumption (a `FindIntersect` whose point hashes were CBOR text strings
  rather than byte strings got us dropped).
* Sustained throughput characteristics (headers stream far faster than
  bodies; both are fine — chain-sync and block-fetch are independent
  protocols and the gap closes at the tip).

---

## 3. The gaps: needed, but specified nowhere (or wrongly)

Each of these cost real reverse-engineering time; each is a candidate for
upstream promotion into CDDL or prose. Each links to the code that is
currently the only specification.

**Code is the only spec (byte-exact algorithms):**

1. **Block body hash** — the header's `block_body_hash` commitment is a
   hash-of-four-hashes over the four "segwit" segments. Only in
   [`hashAlonzoSegWits`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/alonzo/impl/src/Cardano/Ledger/Alonzo/BlockBody/Internal.hs#L189);
   no CDDL or prose states the algorithm. Ours:
   [`ledger/conway/block.ex`](../lib/cardamom/ledger/conway/block.ex).
2. **Operational-certificate signable bytes** — the exact byte concatenation
   an opcert's cold-key signature covers:
   [`OCert.hs`, `getSignableRepresentation` / `ocertToSignable`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/libs/cardano-protocol/src/Cardano/Protocol/TPraos/OCert.hs#L142-L155).
3. **Genesis UTxO derivation** — pseudo-transaction-input construction for
   initial funds:
   [`Shelley/Genesis.hs`, `initialFundsPseudoTxIn`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/shelley/impl/src/Cardano/Ledger/Shelley/Genesis.hs#L647),
   and the Byron variant.
4. **Collateral-return output index** — `TxIx = length(outputs)`, not 0:
   [`Babbage/Collateral.hs` L55](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/babbage/impl/src/Cardano/Ledger/Babbage/Collateral.hs#L55).
   Assuming 0 corrupts UTxO tracking on every phase-2-invalid transaction.
   Our regression test:
   [`store/collateral_return_index_test.exs`](../test/cardamom/store/collateral_return_index_test.exs).
5. **All of Byron** — block/body/tx encodings reconstructed from the decoders:
   [`Chain/Block/Block.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/byron/ledger/impl/src/Cardano/Chain/Block/Block.hs),
   [`Block/Body.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/byron/ledger/impl/src/Cardano/Chain/Block/Body.hs),
   [`UTxO/TxAux.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/byron/ledger/impl/src/Cardano/Chain/UTxO/TxAux.hs),
   [`UTxO/Tx.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/byron/ledger/impl/src/Cardano/Chain/UTxO/Tx.hs)
   (note the tag-24 nested-CBOR `TxIn`, [L168](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/eras/byron/ledger/impl/src/Cardano/Chain/UTxO/Tx.hs#L168)),
   CRC-protected addresses. Ours, with line-cited field mapping:
   [`ledger/byron/body.ex`](../lib/cardamom/ledger/byron/body.ex).
6. **Praos VRF range extension and nonce derivation** — the leader value is
   `blake2b256("L" ‖ vrfOutput)` and the block nonce
   `blake2b256(blake2b256("N" ‖ vrfOutput))` from Babbage onward
   ([`Praos/VRF.hs`, `vrfLeaderValue`/`vrfNonceValue`](https://github.com/IntersectMBO/ouroboros-consensus/blob/73fa2da6a42c273ae723a8830eb7159ab2b6b073/ouroboros-consensus-protocol/src/ouroboros-consensus-protocol/Ouroboros/Consensus/Protocol/Praos/VRF.hs#L110)),
   but the raw output for TPraos eras
   ([`TPraos/BHeader.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/3118136df7b5ccff3ca2f06245ed91d81f50b994/libs/cardano-protocol-tpraos/src/Cardano/Protocol/TPraos/BHeader.hs)).
   Consensus-layer rather than network-layer, but a header validator
   following the chain from genesis needs both.

**Documented wrongly or inconsistently:**

7. The `Codec.hs` mode-bit comment contradicts both the code and `mux.tex`
   (§2.4).
8. The CSPm-era model carried a single `Point` in `FindIntersect` where the
   wire carries a list — *fixed* in the Agda successor
   ([`Data.agda` L91](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/Data.agda#L91), `List Point`),
   noted here for anyone still holding the CSPm file.

**No formal treatment exists:**

9. **The handshake** — the first and most failure-prone exchange on every
   connection has CDDL and prose but no behavioural model.
10. **Timing** — all timeout behaviour (a disconnection cause, §2.6) is
    outside the formal model.
11. **Egress scheduling** — the fairness discipline between protocols sharing
    a bearer is described in prose only
    ([`mux.tex` §Fairness and Flow-Control](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/docs/network-spec/mux.tex#L102));
    `CopySpec` (per-protocol FIFO correctness) is proved, but inter-protocol
    fairness is not modelled.

**Cross-cutting:**

12. **The version-axes tangle** — era numbers, protocol-major versions, wire
    era tags, and negotiated N2N versions do not align and are nowhere laid
    side-by-side; every implementer builds this table themselves
    (ours: [`WIRE.md` §9](WIRE.md#9-era-envelopes--the-numbering-trap)).
13. **Findability** — several artifacts above are correct but effectively
    undiscoverable from each other (nothing links the CDDLs to `network-spec`
    to the formal model). The absence of an index like this document is
    itself the meta-gap.

---

## 4. Minimum viable client (first contact)

The smallest artifact set that gets an implementation talking to a relay:

1. **Handshake** (protocol 0):
   [`handshake-node-to-node-v14.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/handshake-node-to-node-v14.cddl)
   + version data + network magic from
   [`shelley-genesis.json`](https://book.world.dev.cardano.org/environments/preview/shelley-genesis.json).
   Propose v14+; declare `initiatorOnlyDiffusionMode = true` if observing.
2. **Keep-alive** (protocol 8):
   [`keep-alive.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/keep-alive.cddl);
   answer pings promptly or be reaped (§2.6, §2.8).
3. **Chain-sync client** (protocol 2): FSM from the Agda model
   ([`ChainSync.agda`](https://github.com/input-output-hk/agda-cardano-common/blob/ee1f4a2d10d7b16d99e15bc8d9459bb960724a14/src/ITree-CSP/CSP/Examples/Cardano_network/ChainSync.agda#L175-L245))
   or `miniprotocols.tex`; encoding from
   [`chain-sync.cddl`](https://github.com/IntersectMBO/ouroboros-network/blob/a3d8017e798b225055aaf9118ad062fe58bc650f/cardano-diffusion/protocols/cddl/specs/chain-sync.cddl);
   era envelopes from §2.8; header hashing from §2.5.

All of it framed in SDUs per §2.4, all of it strict per the CDDL directive.
Block-fetch, tx-submission, and peer-sharing are additive after that. The
worked, fixture-backed version of this recipe is
[`WIRE.md`](WIRE.md); the bootstrap relay to talk to is in Preview's
[`topology.json`](https://book.world.dev.cardano.org/environments/preview/topology.json).

---

## Revision log

* **2026-09-29** — every citation converted to a pinned permalink plus a
  tracking link, verified against the upstream heads of that day; §0 added;
  §2.1 updated for the branch's move to `(Link, Dir)` indexing and the
  `NetworkVerification/` layout; §2.3 updated for the v14/v15 vs v16
  version-data split (`perasSupport`) and `object-diffusion.cddl`; gap 6
  (VRF range extension) added; TSUNAGI incident linked.
* **2026-07-23** — first version, from the working notes in
  `wire-protocol.md`.
