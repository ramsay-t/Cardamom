# Cardamom — Wire protocol notes (milestone 1: talk to a Preview relay)

The networking layer is *under-specified in prose* and is itself an open spec
project Ramsay cares about (he owns this area). Building Cardamom against a real
Preview relay is partly a way to *generate findings* for the network spec. So:
record where the spec speaks clearly, where it's silent, and every byte-level
ambiguity we hit.

## EPISTEMICS: the CSP is a HYPOTHESIS, not ground truth (Ramsay, 2026-06-08)

The CSP model is the **most formal artifact available, but it may or may not match
the real (woefully under-documented) network behaviour.** Same stance as the Agda
ledger spec — own the formal artifact, treat the running implementation as
de-facto truth, treat discrepancies as FINDINGS — but WORSE here: the ledger has a
conformance bridge to the node; the network has this abstract model on one side
and the under-documented Haskell `ouroboros-network` on the other with **no
established conformance bridge.** The model/reality gap is UNMEASURED.

So Cardamom is a **third triangulation point**: an independent implementation
built from the model, meeting the real wire, reporting where model / prose /
reality diverge. Every Preview-traffic mismatch is a finding — triage (did I
misencode? / CSP dropped this abstraction? / genuine model-vs-reality
divergence?) but **divergences are OUTPUT, not just debug noise.** When the relay
does something the CSP forbids, first hypothesis is NOT "my code is wrong" — log
it.

## WHY PREVIEW, not mainnet (safety + ethics, not just convenience)

An unproven from-scratch impl WILL send malformed SDUs / mis-sequenced messages /
bad handshakes while we get it right. Against mainnet that is: impolite (eating
real infra's connection slots + CPU with garbage), potentially destabilising (our
malformed message meeting a fragile Haskell parser error-path — exactly the
failure Ramsay suspects), and suspicious-unknown-peer behaviour on production.
Against **Preview** it's consequence-free — disposable test net that exists for
this; tripping an error path there is a useful finding, not harm. **Preview is the
RESPONSIBLE default for ALL wire testing, not just M1.** Mainnet, if ever, =
observe-only, post-Preview-proven, ideally against our own relay.

Bonus: on Preview, Ramsay/team can stand up a **known controlled peer** (a real
Haskell node we configure) → when Cardamom and the CSP disagree, compare against a
controlled real implementation rather than guessing. Turns "model vs. mystery"
into "model vs. controlled-real".

## DIRECTIVE: parse the CDDL and ENFORCE it — STRICT, never coerce (Ramsay, 2026-06-08)

**Default instinct (Postel's law, "be liberal in what you accept") is WRONG and
DANGEROUS here.** Real history: a network split was caused by two node versions
treating the CDDL differently — a field said 32 bytes; one node ACCEPTED and
TRIMMED longer values (liberal/coercing), the other REJECTED them (strict). A
malformed-but-coercible on-chain object then made the two populations disagree
about validity → consensus fork. A parsing nuance became a chain split.

So: **parse the CDDL as an ENFORCED GRAMMAR, not a hint. Reject what doesn't fit.
Never coerce, never trim, never "make it make sense."** 32 bytes means exactly
32; 33 is an ERROR, not "32 + slack to discard."

**Two encodings, strict for two different reasons (don't conflate):**
- **On-chain / consensus encoding** (tx bodies, blocks, anything HASHED or
  AGREED): strictness is CONSENSUS-CRITICAL — this is where the split happened.
  Cardano mandates CANONICAL/deterministic CBOR so one logical object has exactly
  one byte form so hashes agree. Liberal parsing here = forks. Max strictness.
- **Network-transport encoding** (chain-sync envelopes, mux header): mis-framing
  won't split the chain, but for US strictness is the MEASUREMENT INSTRUMENT —
  leniency HIDES the model-vs-reality divergences we exist to catch. Every
  rejection is a signal to log.
  → Same behaviour (enforce, don't coerce) both places; on-chain because leniency
  CAUSES forks, on-wire because leniency HIDES findings.

**Load-bearing for MILESTONE 1:** to check `parent == hash(prev)` we HASH a
header → consensus-encoding territory at M1. The hash matches ONLY if we treat
bytes exactly as canonical encoding demands. Wrong strictness → hash-chain won't
link → M1's entire success criterion fails. Strictness is not a later refinement;
it's required for the first thing we want to see work.

**CBOR library caveat (VERIFY, don't assume):** earlier "CBOR is solved" was too
glib. *General* CBOR is solved (hex `cbor`); *canonical-strict* CBOR is a stricter
requirement and the library may NOT meet it (may ignore trailing bytes / accept
non-canonical forms). Must verify: does it do deterministic encoding + strict
decode? If not, wrap/replace. Any silent coercion the lib does = a bug for us
(masks findings, replicates the split's failure mode).

**This anecdote IS a test case / spec probe:** "Cardamom rejects an over-long
bytestring where CDDL says fixed-length" — a known divergence point, high-value
conformance test. Cite this real split.

## Conway CDDL (on-chain encoding) — milestone 1 header structure

`~/GoogleDrive/IOHK/cardano-ledger/eras/conway/impl/cddl/data/conway.cddl`
(cardano-ledger @ cd8b7fa, 2026-06-03). The on-chain / consensus-critical
encoding — STRICT-ENFORCE side of the CDDL directive.

M1-relevant grammar (the strict targets):
- `header = [header_body, body_signature : kes_signature]` (2-elem array).
- `header_body = [block_number, slot, prev_hash : hash32/nil, issuer_vkey,
  vrf_vkey, vrf_result, block_body_size : uint.size 4, block_body_hash : hash32,
  operational_cert, protocol_version]` (10 fields).
- `hash32 = bytes .size 32` ← **the exact field type from Ramsay's network-split
  anecdote.** First concrete strict-enforce target: exactly 32 bytes, reject 33.
- `kes_signature = bytes .size 448`.

**M1 hash-chain mechanics (pin this down — silently breaks M1 otherwise):** the
chain link is `prev_hash` in header_body. "Hash chain links" = blake2b-256 of
header N == header N+1's `prev_hash`. CRITICAL: hash the **received header bytes**,
NOT a re-encoding — if we re-serialize and bytes differ from what arrived, the
hash won't match. Canonical-encoding strictness bites exactly here. (header also
carries block_body_hash → body; body fetch is M2.)

## FINDINGS from the CDDL (raise w/ Ramsay)

- **(epistemics)** `conway.cddl` line 1: "auto-generated using generate-cddl, do
  not modify directly". It's RENDERED from `HuddleSpec.hs` (Huddle DSL). Huddle
  is upstream truth; `.cddl` is derived. The "big debate" Ramsay mentioned may
  live in Huddle source/history, not the rendered `.cddl`.
- **(gap)** CDDL is necessary but NOT sufficient to validate a block: some
  constraints are PROSE COMMENTS the grammar can't express (e.g. lines 3–7:
  "transaction_bodies & transaction_witness_sets same length"; "transaction_index
  < length"). So strict-CDDL-enforce ≠ full validation; those rules live in
  ledger rules / Huddle / comments. Worth flagging: a from-scratch implementer
  enforcing only the CDDL would MISS these.

## CSP STRUCTURAL FIDELITY — house rules (Ramsay, 2026-06-08)

The Elixir must respect the CSP **structurally**, not just semantically — code
branch structure mirrors the process-algebra structure (Ramsay taught
Erlang+CCS in parallel). Mini-protocol FSMs are `:gen_statem`; CSP process names
→ state names; CSP line ranges cited per state.

Mapping: named process `P(args)` → state (name = process, args = data); prefix
`c.x->P'` → handle event then `{:next_state, P', ...}`; recursion `P=..->P` →
`{:next_state, same, ..}`; `SKIP`/`Done` → `{:stop,:normal,..}`; guards `(c)&P` →
guard clauses; `c?x` → receive+bind; `c!v` → encode+send.

**RULE 1 — send-last, then a receiving state (recovers CSP rendezvous on async
BEAM).** Send is the LAST action before `{:next_state, …}`, and the next state
begins by waiting/receiving. CSP theory: the work *between* two sync points
(send, then receive) is unobservable / doesn't matter (τ, confluent) — so the
async mailbox IS the synchronous channel as long as each state ends with ≤1 send
then transitions to a receiving state. No need to fake sync in the mux or expose
async — the FSM discipline makes them equal, async confined to the "doesn't
matter" gap. State shape: `do local work; (≤1) encode_and_send; {:next_state,
:st_next, data}` where :st_next starts by receiving.

**RULE 2 — every FSM is ALL external choice (receive-first); apparent internal
choice means a missing DRIVER process to factor out.** Refined by Ramsay
(2026-06-08), this is how he taught CSP/CCS:

Internal choice `|~|` is just external choice `[]` with the deciding
communication HIDDEN. So when an FSM state looks like it "decides" (the `StIdle`
`SendCSMsg…` case), the faithful model is: a separate **Driver** process makes
the decision (its `|~|`, honest internal choice = policy/consensus), and drives
this FSM by *messaging* it on control channels; compose in parallel and HIDE the
control channels (`\ {|SendCSMsg…|}`). Then:
- viewed alone, the FSM is **external choice** — it receives a control message and
  reacts (receive-first ✓);
- the hidden control rendezvous is invisible to the environment, so externally it
  **appears as internal choice** — internal choice = external choice + hiding.

**The hiding bubble IS the node boundary.** The peer sees only
`sendChainSync`/`receiveChainSync` on the socket, never the `SendCSMsg…` control
traffic between our driver and our FSM (internal BEAM messages). So:
- **Every protocol FSM = pure external choice, every branch a guarded receive.**
  The FSM never decides; its "environment" is the peer OR our own driver.
- **All genuine decisions live in named DRIVER processes** whose `|~|` is honest
  (resolved by policy/consensus).
- **Agency predicts the drivers:** a `[C]`-agency state (we hold agency, e.g.
  `StIdle`) is exactly where a driver is needed — "we hold agency" ⟺ "a hidden
  driver decides". `[S]`-agency states are peer-driven external choice directly.

OTP realisation = the SAME construction: the Driver is a separate process (the
consensus/chain-selection driver) sending control messages to the chain-sync
`:gen_statem`; "hidden" = internal to the node, off the wire.

**RULE 3 — STANDING INSTRUCTION: apparent internal choice inside an FSM ⇒ factor
out a driver process; if it can't be factored that way, RAISE IT.** Internal
choice in an FSM is not a thing to tolerate — it's a refactoring smell with a
known fix (split out the driver, hide the control channel). Only if an apparent
internal choice genuinely cannot be expressed as driver+external-choice+hiding
do we STOP and raise it (CSP line numbers + what doesn't fit). Don't silently
fudge. (Process-structure analogue of strict-CDDL "don't coerce".)

### First application — chain-sync client checked (holds, with the driver factoring)
- `StIdle` (491–509): offers three `SendCSMsg…` CONTROL inputs (473–475) → it
  RECEIVES from a driver → **external choice** ✓. The decision (RequestNext /
  FindIntersect / Done) lives in a separate **Driver** process (the
  consensus/chain-selection driver); its choice is the honest `|~|`; the control
  channels are hidden inside the node boundary, so externally StIdle looks like
  internal choice. NOT mislabelled — it's external-choice-under-hiding. (My
  earlier "internal choice" reading was standing outside the bubble.)
- `StCanAwait` (512–528): receive-first, peer-driven → external ✓ ([S]).
- `StMustReply` (531–542), `StIntersect` (545–554): receive-first → external ✓.
- **All four states are external choice / receive-first** once StIdle's driver is
  factored out. Decisions concentrate in the driver. Structural fidelity total.

## Authoritative behavioural source: the CSP model

`~/Downloads/mini_protocols_KA_BF_CS_Tx_20260514.csp` (CSPm / FDR; dated
2026-05-14). A machine-checked process model of the Cardano multiplexer + four
mini-protocols (KeepAlive, BlockFetch, ChainSync, TxSubmission2). **This is the
authoritative spec for protocol LOGIC** (message sequencing + agency + the client/
server state machines) — the genuinely hard part that prose gets vague about.

What it pins down (high-confidence transcription targets):
- **ChainSync client FSM** (lines ~491–554): `StIdle` (client drives:
  RequestNext / FindIntersect / Done) → `StCanAwait` (server: AwaitReply OR
  RollForward h t / RollBackward p t) → `StMustReply` (after await, must reply
  fwd/back) → `StIdle`; `StIntersect` (IntersectFound/NotFound). The
  AwaitReply→StMustReply two-step is the subtle bit, explicit here.
- ChainSync message set (~460–468): RequestNext, AwaitReply,
  RollForward(Header,Tip), RollBackward(Point,Tip), FindIntersect([Point]),
  IntersectFound(Point,Tip), IntersectNotFound(Tip), Done.
- Mux SDU logical structure (~5–8): `TxTime | M(mode) | MiniProtocolID |
  PayloadLength | Payload`. Mode = FromInitiator | FromResponder.
- Mini-protocol IDs (~15–21): ChainSync=2, BlockFetch=3, TxSubmission=4,
  KeepAlive=8, (Handshake=0, PeerSharing=10 — commented out).
- Mux correctness (~88–90): `CopySpec [FD= Network` (+ reverse) — the mux must
  behave as one independent lossless FIFO buffer per protocol ID. This is the
  CONTRACT our mux must satisfy.

Transcription: CSP `ChainSyncClientPeer_*` → Elixir `:gen_statem` almost
line-for-line (states = the St* functions; `[]` external choice = event branches;
`sendChainSync.…` = encode+write; `receiveChainSync.…` = handle incoming).
Tests can cite "CSP ChainSyncClientPeer_StCanAwait, lines 512–528".

## What the CSP model deliberately ABSTRACTS (FDR needs finite state) — THE GAPS

These are exactly the prose-vague layers, AND they're abstracted here, so filling
them is the open work (and a likely source of spec findings):

- **Concrete encoding / CBOR / CDDL: NOT here.** Length = {0..1}, Payload abstract
  (`Data = Session.Messages`). Model knows RollForward carries (Header,Tip); NOT
  the bytes. → get from ouroboros-network CDDL + reading Haskell.
- **Handshake / version negotiation / network magic: NOT here.** N2N_Handshake
  (id 0) explicitly commented out. This is the FIRST thing on the wire and what
  REJECTS us on Preview if wrong, and it's unmodelled. → cardano config for
  Preview network magic; ouroboros-network handshake CDDL.
- **Quantitative / timing: NOT here.** Time = {0..0} (real SDU header has a 32-bit
  µs timestamp); timeouts, keep-alive timing, and the egress queue's
  priority/fairness scheduling (mentioned in prose ~142–144) unmodelled.
- **Blocks/Points/Headers toy** (Block = b1|b2): no real hashes/structure.
- Model's own ToDos: lines ~583, ~740, ~808 — author flags underspecified points.

## SPEC FINDINGS / FLAGS to raise with Ramsay (per his "raise lots" instruction)

- **(gap)** Handshake — the first & most failure-prone exchange — has no formal
  model here. Is there a separate handshake model, or genuinely unmodelled?
- **(clarity)** `MsgCSFindIntersect` carries one `Point` here vs `[Point]` on the
  real wire (comment ~457–459 is honest about it) — model/wire arity diverges.
- **(clarity)** SDU egress scheduling discipline (priority/fairness between
  protocols on one socket) is in prose (~142) but unmodelled — a real behavioural
  question (inter-protocol fairness) pinned down nowhere.

## Mux design notes — read from `network-mux/src/Network/Mux.hs`

How the multiplexer shares one TCP bearer across mini-protocols (verified against
source):

- **No head-of-line blocking by design.** `Mux.hs` (~190–219, under a comment
  analysing head-of-line blocking) gives each protocol-direction a one-slot
  buffer (`Wanton`) placed on a shared `tsrQueue`; the egress muxer takes a fixed
  number of bytes (one SDU) per turn and requeues any remainder at the back. This
  is round-robin, fixed-chunk scheduling — statistical time-division multiplexing
  — so a large block-fetch batch cannot monopolise the bearer; keep-alive and
  chain-sync still get turns. (Note for design discussions: "a big batch stalls
  keep-alive" is false — the scheduler prevents it.)

- **BEAM equivalence.** On the BEAM, sharing one bearer fairly across protocols is
  provided by the runtime scheduler over N processes, rather than an
  application-level scheduling queue. So our mux layer is a thin socket-owner
  (deframe inbound / write whole SDUs outbound); the scheduling fairness comes
  from the runtime. The SDU framing itself is mandatory wire format and is honoured
  in `Connection`.

- **Block-fetch requests a contiguous range, not an arbitrary set.**
  `msgRequestRange = [0, point, point]` — you request a chain *range*, and bodies
  stream in chain order. There is no message to request an unordered set of block
  hashes; that ordering is intrinsic to what a range is.

**Design observation (relevant to goal (a)):** per-peer in-order delivery is
re-derivable at the consumer regardless, because a node following multiple peers
must tolerate cross-peer disorder anyway and re-orders by parent-hash (the
forest). So an order-free, content-addressed fetch with single-point reordering
is a coherent BEAM-native alternative worth demonstrating. This is an
*exploration*, not a proposed change to the production protocol — for first
contact we speak the existing range-based block-fetch and SDU framing as the
relay requires.

## SDU header — byte-level spec (READ FROM SOURCE; no prose spec existed)

Authoritative source: `network-mux/src/Network/Mux/Codec.hs` (`encodeSDU` /
`decodeSDU`) + `Types.hs`. Documented here because the byte-level format is
defined in the reference implementation rather than a standalone prose spec —
this section is that spec, written down.

**8-byte header, big-endian, then payload:**

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    transmission time (u32)                    |   bytes 0-3
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|d|         mini-protocol num (15b)         |    length (u16)   |   bytes 4-7
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         payload (length bytes)                ...
```

- **bytes 0-3** `transmission time`: `Word32`, big-endian. Microsecond ticks
  (`remoteClockPrecision = 1e-6`); wraps ~every 4295 s. It's a monotonic-ish
  local clock stamp, not wall-clock. Receivers largely don't act on it; set it
  from a µs clock on send. (CSP abstracted this to {0..0}.)
- **bytes 4-5** `Word16` = `(dir_bit << 15) | (mini_protocol_num & 0x7fff)`:
  - top bit (`0x8000`) = direction; low 15 bits = mini-protocol number.
- **bytes 6-7** `length`: `Word16`, big-endian = payload byte count. **Max payload
  per SDU = 12288** on the standard socket bearer (`Bearer.hs`: SDUSize 12_288;
  other bearers 32768/24576/1280). Larger logical messages split across SDUs.
- **payload**: exactly `length` bytes (the CBOR-encoded mini-protocol message,
  whole or a fragment).

**Encode/decode:** `putWord32be ts; putWord16be (num|dir); putWord16be len; <blob>`.
Decode reverses; `mhNum = a .&. 0x7fff`, dir from `a .&. 0x8000`.

### FINDING — direction bit: CODE CONTRADICTS ITS OWN COMMENT (raise w/ Ramsay)
`Codec.hs` prose comment (lines 29-32) says: "d: 1 = initiator, 0 = responder."
The CODE says the OPPOSITE: `putNumAndMode n InitiatorDir = n` (bit=0);
`ResponderDir = n .|. 0x8000` (bit=1); and `getDir`: `0x8000==0 -> InitiatorDir`.
**CODE IS TRUTH (per epistemics): bit 0 = initiator, bit 1 = responder.** The
comment is a documentation defect in the source. Concrete spec-finding — exactly
the kind of "the only spec is the code and the code's own docs are wrong" issue
this project surfaces. As the INITIATOR (we dial out), we send dir bit = 0.

## Transport CDDL + sources (ouroboros-network, local)

`~/GoogleDrive/IOHK/ouroboros-network` (@ d842a23, 2026-05-22). Fills what the
CSP abstracts and the ledger CDDL lacks:

- **chain-sync wire encoding** — `.../cddl/specs/chain-sync.cddl`. Maps 1:1 to
  the CSP message set; each msg = CBOR array with leading int tag:
  RequestNext=[0], AwaitReply=[1], RollForward=[2,header,tip],
  RollBackward=[3,point,tip], FindIntersect=[4,points], IntersectFound=[5,point,
  tip], IntersectNotFound=[6,tip], Done=[7]. **CSP gives sequencing/agency; this
  gives encoding — together ≈ complete chain-sync client spec.**
- **handshake + network magic** — `handshake-node-to-node-v14.cddl` +
  `node-to-node-version-data-v14.cddl`:
  `nodeToNodeVersionData = [networkMagic:word32, initiatorOnlyDiffusionMode:bool,
  peerSharing:0..1, query:bool]`. networkMagic rejects us on Preview if wrong;
  its VALUE is config (not in CDDL) → get from cardano-configurations/Preview
  genesis. **`initiatorOnlyDiffusionMode = true` IS our observer role expressed
  in the handshake — the protocol has a first-class "I only initiate, won't
  serve" flag, validating observer-first.**
- **mux SDU framing** — `network-mux/src/Network/Mux/{Codec,Types}.hs` (de-facto
  truth for the 8-byte SDU header).
- **de-facto-truth Haskell** — handshake/protocol `Codec.hs`/`Type.hs`/
  `Version.hs` for triangulation when CSP/CDDL/reality disagree.
- Versioning is real & on-wire: v14 current, v11–13 obsolete/. Target v14; check
  what Preview actually negotiates.

## What the real node ENFORCES → what closes/blacklists a peer (read from source 2026-06-15)

SimPeer must enforce these so "sim-green" means "Preview-ready" — a fake more
lenient than reality gives false confidence. Read from
`ouroboros-network/protocols/lib/.../{ChainSync,KeepAlive}/Codec.hs`. Three
enforcement axes; violating any → the connection is killed:

1. **Agency / state-respecting decode.** Decoders pattern-match on
   `(current_state, list_length, message_key)` and `fail` on anything else (the
   KeepAlive `case (stok, len, key)` is the model). So a message sent **in the
   wrong state (no agency)**, with **wrong arity**, or an **unknown key** →
   protocol violation → closed. (This is exactly our strict-CDDL enforcement,
   confirmed as the real behaviour.)

2. **Per-state byte size limits.** Every chain-sync / keep-alive state has a max
   message size (`smallByteLimit`). Exceeding it → instant violation → closed.

3. **Per-state timeouts.** Chain-sync `StMustReply` timeout is **601–911 s**
   (`minChainSyncTimeout`/`maxChainSyncTimeout`, randomised in that window): after
   the server sends `MsgAwaitReply` it MUST deliver a roll-fwd/back within that
   window or it's a timeout violation. `StIdle` has a configurable idle timeout.
   Symmetric for us-as-client: keep driving / answer promptly or risk being
   dropped.

KeepAlive message shapes (verified, mini-protocol 8):
`MsgKeepAlive = [0, word16-cookie]` (listLen 2), `MsgKeepAliveResponse =
[1, word16-cookie]` (listLen 2), `MsgDone = [2]` (listLen 1). Cookie is word16,
must round-trip. NB the listLen is 2 for the cookie messages (key + cookie).

**SimPeer enforcement plan:** demux by protocol number; for each protocol, only
accept messages valid for the current agency-state (else simulate close); enforce
a size cap; and optionally a (short, test-scaled) timeout to exercise our
client's liveness. Reproduces the real close/blacklist triggers so passing the
sim means we won't get dropped by Preview for a protocol-correctness reason.

## Preview network magic = 2 (verified 2026-06-11)

`networkMagic = 2` for Preview testnet (mainnet 764824073, preprod 1). Goes in
the handshake `nodeToNodeVersionData = [networkMagic, ...]` as a word32. WRONG
VALUE = instant handshake rejection. Source: cardano docs / `--testnet-magic 2`.

## Barest-minimum protocol set to stay connected to a Preview relay

To open a connection and NOT get kicked off, the minimum is:

1. **Handshake (mini-protocol 0) — MANDATORY, always first.** Propose
   NodeToNode version(s) (target v14+), send `nodeToNodeVersionData =
   [networkMagic=2, initiatorOnlyDiffusionMode=true, peerSharing=0, query=false]`.
   `initiatorOnlyDiffusionMode=true` declares "I only initiate, won't serve" =
   our observer role on the wire. Must agree a version or we're dropped.
2. **KeepAlive (mini-protocol 8) — effectively mandatory to STAY connected.**
   Trivial: `msgKeepAlive=[0,word16(cookie)]` → peer replies
   `msgKeepAliveResponse=[1,same cookie]`; `msgDone=[2]`. We must answer the
   peer's keep-alives (and/or send our own) or the connection times out and we're
   reaped. This is the cheapest possible "prove I'm alive" protocol — ideal first
   real protocol to implement.
3. **ChainSync (mini-protocol 2) — the actual point of M1.** Once handshaked +
   kept alive, run the chain-sync client (FindIntersect once → loop RequestNext)
   and watch real Preview headers arrive + parent-hashes chain up.

NOT needed for M1: BlockFetch (bodies = later), TxSubmission (we're an observer),
PeerSharing. So: **Handshake + KeepAlive + ChainSync.** KeepAlive is the barest
"stay connected" protocol; ChainSync is the barest "do something useful" one.

## Milestone 1 work split

1. **Transcribe the logic** — ChainSync client `:gen_statem` from the CSP. Have
   the spec; high-confidence.
2. **Fill encoding + handshake + framing** — NOT in CSP, vague in prose. From
   ouroboros-network CDDL, cardano Preview config (network magic), Haskell.
   THIS is where building generates network-spec findings.

CBOR itself is a solved library problem: hex `cbor` (`CBOR.encode/1`,
`CBOR.decode/1` returns `{:ok, term, rest}` — streaming-friendly, exactly right
for pulling framed messages off a buffer).
