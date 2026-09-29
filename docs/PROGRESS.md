# Cardamom — progress log

*The single place that says what is done, what is half-done, what is open, and
what is waiting on a decision. Updated at the end of every working session;
newest session first in §4. Public and committed, unlike the private working
notes, so it survives a lost laptop. Started 2026-09-29.*

Conventions: **DONE** = built, tested, committed. **BUILT** = built and tested
but not yet committed or not yet wired in. **OPEN** = not started or not
finished. **DECISION** = blocked on Ramsay's call.

---

## 1. Where things stand (2026-09-29)

**Tree:** `main`, in sync with `origin/main` as of the two doc commits today,
plus a **staged, uncommitted** 21-file batch from 2026-09-02 (η registers,
leader oracle, VRF-output consistency; 1,297 insertions). Compiles clean
with `--warnings-as-errors`; **937 tests, 0 failures** with that batch
included.

**Live data:** `data/forest-2.db` last written 2026-08-04 (node stopped since).
Headers: 1,630,470 in 102 disconnected segments; genesis-contiguous only to
epoch 51. Blocks: 891,936 stored, 869,830 processed. No ledger fold has ever
run on the live DB (one `ledger_state` row, empty `ledger_deltas`); all
epoch/reward/η machinery has run only in tests and the read-only sweep.

### Network layer

| Area | Status |
|---|---|
| Mux SDU codec + reassembly | DONE, fixture-pinned |
| Handshake (v14, Preview only, mainnet refused) | DONE; v16 `perasSupport` not handled (fine while we propose 14 only) |
| Chain-sync client, pipelined, resume-from-tip | DONE |
| Block-fetch client, proactive backfill to genesis | DONE |
| Keep-alive + dead-peer detection + auto-reconnect | DONE (commit d7f6e9a) |
| Peer-sharing client (record only, never dial) | DONE, off by default |
| Tx-submission | **BUILT but wrong on two counts, see §3.1**; off by default; never run against Preview |
| Inbound connections / responder side | OPEN, deliberately (out of scope without an explicit decision) |
| Leios wire (Dijkstra era 7) | scaffolded; EB/vote/cert payloads are placeholders |
| Network documentation (`network-specs.md`, `WIRE.md`) | DONE; links pinned 2026-09-29; consensus era-envelope CDDLs cited |

### Decoding and storage

| Area | Status |
|---|---|
| Headers, all eras, shape-dispatched (15 / 10 fields), hash-verified | DONE |
| Blocks, all eras Byron→Conway, body-hash verified before storage | DONE |
| Tx bodies, certificates, governance proposals/votes | DONE (voting_procedures decoded; see §2) |
| Full UTxO set, collateral-return index rule | DONE |
| SQLite (Ecto) durable store + Nebulex hot cache | DONE (decided, don't re-litigate) |
| DB size (raw bytes everywhere, ~13 GB) | txos.raw dropped; retention mode for processed blocks OPEN |

### Header validation (Tier 1)

| Area | Status |
|---|---|
| Opcert cold-key signature | DONE, gates storage |
| KES Sum₆ verification (pure Elixir) | DONE, gates storage |
| VRF ECVRF draft-03 verifier (pure Elixir) + output consistency | DONE / BUILT (staged batch) |
| Chain continuity | DONE |
| η (epoch nonce) evolution, five-register model | BUILT (staged); reproduces 21/21 published Preview nonces in the sweep |
| Leader-election oracle (σ from SET snapshot, "L" range extension) | BUILT (staged), wired to the gate; skips honestly on live data until a replay builds snapshots |
| η₀ seeding in `Genesis.load` | OPEN (small) |

### Ledger state (non-UTxO) and block validation gate

| Area | Status |
|---|---|
| Certificate effects, withdrawals, deposits, pots, invertible delta journal | DONE |
| Epoch boundary: snapshots, reward engine (exact rationals) | DONE in tests; never run on live data |
| Value conservation + withdrawal oracle in the gate | DONE |
| Phase-1 tx rules: witnesses, native scripts, validity interval, min fee, size, cert preconditions, min-ADA policy | DONE |
| Gov-action state tracking, wired into block pipeline | DONE |
| Ratification: acceptance predicate + threshold table | DONE (pure) |
| Ratification wired into the epoch transition (active sets, delay, enactment, deposit refund) | OPEN, the remaining piece for "validate Conway blocks end-to-end" |
| Enacted-parameter tracking (mechanism) | DONE; goes live only via replay |
| Plutus (phase-2) execution | OPEN by design; not planned |
| TxValidation as independent context-injected process (chain / replay / mempool policies) | DONE |

---

## 2. Open work, in the order we intend to do it

1. **Commit the staged η / leader-oracle batch.** Green; needs Ramsay's signed commit.
2. **Tx-submission correctness** (§3.1): era-wrap tx ids and txs in the codec and the simulated peer, using the `ouroboros-consensus` golden files as byte-exact fixtures; add a role knob to `Peer.Session`; run the submitter role against Preview from a params copy.
3. **Seed η₀** in `Genesis.load` and make `Replay` verify each computed epoch nonce against the recorded one as it folds (port the scratchpad sweep into `scripts/`).
4. **Header-gap backfill** so the genesis-contiguous segment reaches the tip (replay prerequisite). DECISION on approach.
5. **From-genesis replay** on a fresh DB: proves leader threshold, reward engine and enacted params over real history. DECISION: the DB wipe.
6. **Ratification into the epoch transition** (closes the governance loop; the last piece of end-to-end Conway validation).
7. `ledger_read` → `Cached` hot-path sweep.
8. Raw-block retention mode (opt-in, drop raw for processed blocks) to shrink the DB.
9. Multi-peer operation and chain selection between competing peers.
10. Wire-spec upstream reports (§3.3).

---

## 3. Known defects and findings

### 3.1 Tx-submission is on the wrong side and uses the wrong encoding (found 2026-09-29)

- **Wrong side.** On our outbound, initiator-only connections we are the tx-submission *client*, which the model defines as the *submitter*: it sends `MsgInit` and answers requests. Our `:receiver` role sends `RequestTxIds`, the responder's message. A Haskell relay would treat that as a protocol violation. Receiving gossip requires the responder half, i.e. accepting an inbound connection from a peer that dials us.
- **Wrong encoding.** Wire tx ids are `[eraIdx, hash32]` and txs `[eraIdx, #6.24(bytes)]` (consensus node-to-node CDDL, `encodeNS`, and the golden file `GenTxId_Conway` = `82 06 58 20 …`). Our codec and simulated peer use bare hashes and bare bytes, so they agreed with each other and never caught it.
- **Consequence.** Mempool observation has run live only in the block→mempool direction (block-fetch feeding the mempool tables). The gossip direction has never run against Preview: `preview.params` has never enabled it, every tx-submission log line carries a test peer label, and the live mempool tables are empty. README and earlier notes overstated this.

### 3.2 Header store gaps
102 disconnected header segments in the live DB; genesis-contiguous only to epoch 51. "All headers from genesis" does not currently hold. Replay needs the holes filled first (§2 item 4).

### 3.3 Upstream findings still to report
Mode-bit comment in `Network.Mux.Codec` still backwards at main (2026-09-15). Body-hash, opcert signable bytes, genesis UTxO derivation, collateral-return index, all of Byron: Haskell-only algorithms. `txId.cddl` argument order disagrees with the Haskell era index and the test cannot detect it. Nothing in `ouroboros-network` points at the consensus era-envelope CDDLs. Full list: `network-specs.md` §3.

### 3.4 Docs to correct
README "What works today" claims live mempool observation; it should say block-side only until §3.1 is fixed. README "Not yet done" still lists KES/VRF header verification, which has landed.

---

## 4. Session log (newest first)

**2026-09-29** — Network docs made outsider-usable: every upstream citation a pinned permalink + tracking link, §0 repository map, 79 URLs verified. Found the `ouroboros-consensus` node-to-node CDDLs (era envelopes for header, block, tx, txId) on Ramsay's prompt; added §2.9 and gaps 14–15. Found tx-submission is sim-only, on the wrong protocol side, and bare-encoded (§3.1). Two doc commits pushed. Started this log.

**2026-09-02** — η stack validated against published ground truth: 21/21 Preview epoch nonces reproduced. Four spec-fidelity bugs fixed (VRF "L"/"N" range extension; Praos vs TPraos nonce derivation; five-register model with correct lag; 3k/f freeze window through Babbage per erratum 17.3). σ from SET snapshot. Leader oracle wired to the gate. Data findings: Preview starts in TPraos (epochs 0–2); header store has 102 gaps; no live ledger fold. Batch staged, not committed.

**2026-08-23** — Ratification threshold table + acceptance predicate; gov-action state wired into the block pipeline; MC/DC coverage pass; Tier-1 continuity; VRF output-consistency gate. Last commits on `main` before today.

**2026-08-04 to 08-19** — Pure-Elixir KES and VRF verifiers live in the header gate; enacted-param tracking; governance decode; native-script validation end-to-end; min-ADA policy; TxValidation as an independent step; phase-1 rules in the gate.

**2026-07** — Header validation pipeline (decode → validate → store gate); opcert check; header-shape dispatch resolved; era-tag numbering resolved; network resilience (dead-peer + reconnect); `network-specs.md` and `WIRE.md` written.

**2026-06** — First contact with Preview (2026-06-20); mux reassembly bug fixed (the "relay stall" that was ours); chain-sync pipelining; block-fetch backfill; SQLite/Nebulex store decided; UTxO set; mempool tables; tx-submission client (against the simulated peer only).
