# Cardamom — Architecture

*A Cardano node reimplemented on the BEAM (Erlang VM) in Elixir.*

Status: design, pre-implementation. Last updated 2026-06-08.

## Project targets (Ramsay's north stars, 2026-06-11)

Three stated goals, each a different shape of system; every scope decision should
serve these:

**(a) Network layer + BEAM interop.** Learn the (under-documented) network layer
and demonstrate interoperability with a BEAM-native multiprocess implementation.
The deliverable is partly the working connection but largely the *evidence* about
how the network layer maps onto the BEAM's process model — so the CSP-fidelity,
thin-mux, concurrent-gather architecture and the findings notes are first-class
outputs, not asides. Live Preview connection = the proof; the architecture
write-up = the point. (Nearly there: handshake + chain-sync built.)

**(b) Retain enough chain data to answer queries like "current state/datum of
contract XYZ".** This is the most demanding goal and it UN-DEFERS the ledger:
- Needs **block-fetch** (datums are in tx outputs in block BODIES, not headers) —
  so headers-only is insufficient; block-fetch becomes required.
- Needs **live UTxO + datum state TRACKING** (apply blocks, maintain the unspent
  set with datums) — the "light" part of the two-natured ledger state. NOTE: this
  is *state tracking*, NOT full script validation — we can track what UTxOs exist
  and their datums without re-running Plutus. But it's real ledger bookkeeping,
  more than "trust everything, skip the ledger" implied.
- Needs the **SQL analytical store** (the deferred SQLite/Ecto layer) — "ask
  questions like X" = SELECT against tracked state. (b) is what justifies it.

**(c) Observe flows and events — chain AND mempool — to understand behaviours.**
The observational/forensic goal, and the one the forensic-store design was FOR:
- chain flows → candidate-forest lifecycle (born/promoted/forgotten, forks,
  rollbacks) → the forensic store.
- mempool flows → **tx-submission** observation → txs born/included/dropped/
  replaced/expired. (See the mempool-observation notes in CLAUDE_NOTES.)
- Both are the SAME lifecycle shape feeding the SAME forensic/telemetry spine.
  Spine is built; needs the real event sources (esp. tx-submission) wired in.

**Roadmap serving all three:** chain-sync (done) → block-fetch (b) →
tx-submission (c) → ledger UTxO+datum tracking (b) → SQL analytical store (b).
(a) served throughout by keeping the BEAM-vs-Haskell comparison explicit.

## What we are building (and what we are not)

The first target is the **lightest coherent node: a chain-following observer.**
It connects *outbound* to upstream relays, follows the chain, validates it, and
accumulates ledger state — but it **serves nothing downstream** and has no
block-production duty.

This is deliberately lighter than a relay node. A relay does everything a node
does *except* produce blocks, including **serving** chain-sync / block-fetch /
tx-submission to downstream peers. The observer drops all the *obligation*
roles (serving peers, gossiping txs) and keeps all the *interesting* parts
(multi-peer sync, per-protocol state machines, chain selection, ledger
validation).

The progression only ever *adds* roles, never rebuilds:

```
observer  →  relay (add server sides + tx-submission)  →  block producer
```

### Fidelity: semantic model first

We are **not** wire-compatible with mainnet on day one. We use native Elixir
terms as the "wire format", structured so that a real CBOR codec and the real
Ouroboros handshake can slot in later **behind a defined seam**. The goal is to
exercise the behaviour and concurrency, not to reproduce byte-exact encodings.

### Scope: single era — Conway

We model a **single era: Conway** (the current mainnet era), not the full
Byron→Conway progression. Chosen for maximum fidelity and because it's the
authoritative era for spec citation — we model what mainnet runs. The governance
weight (DReps, voting, treasury) is real but concentrated in the
epoch/governance rules; the per-block UTxO core (where we start) is tractable,
and governance is scoped as we reach it. Spec era: `src/Ledger/Conway/` in the
formal-ledger-specifications repo. (PreConway and the in-development Dijkstra era
are also present in the spec but out of scope.)

## Observability — wired in from the start

A concurrent distributed system is miserable to debug without observability from
day one, so both of these go in early (decided 2026-06-09):

### Logging + instrumentation: built-in `Logger` + `:telemetry`

- **`Logger`** (built into Elixir; the "nice one", now better) for human-readable
  logs. Use **structured metadata** — tag every line with `peer:`, `protocol:`,
  `slot:`, etc. — so one conversation is traceable through the concurrency.
  Async with back-pressure (won't stall the network hot path); sits on Erlang
  `:logger` so it captures crashes/supervisor reports uniformly.
- **`:telemetry`** (tiny ubiquitous dep) for structured *instrumentation events*
  emitted at key points, e.g. `[:cardamom, :chainsync, :rollforward]` with
  measurements + metadata. Anything can subscribe: the logger, a metrics store,
  AND the browser UI. **This is the one event spine** that the logs, the forensic
  store (fork-closure / lifecycle events), and the UI all hang off — not three
  ad-hoc mechanisms.

### Browser UI: `Bandit` + `Plug.Router` + `Jason` (no framework)

Deliberately NOT Phoenix. The model is hand-coded: match method+path, return a
hand-coded HTML page (with hand-coded JS that hits other URLs returning JSON).
`Plug.Router` IS that model almost verbatim — "half a step up from a handcoded
handler", just the request-parsing+routing we'd otherwise write by hand:

```elixir
get "/"           -> send_resp(conn, 200, handcoded_html())
get "/stats.json" -> send_resp(conn, 200, Jason.encode!(stats()))
get "/tip.json"   -> send_resp(conn, 200, Jason.encode!(latest_block()))
```

Three small/stable deps: `bandit` (server), `plug` (conn/router), `jason` (JSON).
We own all HTML/JS/routes; no framework, templating, or asset pipeline. Purpose:
view live stats, the latest block, peers/tips, recent rollbacks.

**Discipline — the UI is a READ-ONLY observer.** It reads node state through a
clean read-only seam (a status API / a `:telemetry` handler), never reaches into
process internals, never drives the node. Same rule as "forensic store is
write-only from the node's perspective". The UI observes; it never steers.

## Testing strategy (TDD throughout — three layers)

The actor model IS the mocking framework — a "mock peer"/"mock socket" is just a
test process, so we need almost no networking-specific test libraries.

1. **Pure-function tests (bulk; where strict-CDDL lives).** SDU codec, CBOR
   message encode/decode, parent-hash check — pure functions on binaries, plain
   `ExUnit`. TDD bites first here:
   - round-trip: `encode |> decode == original`
   - **strict-parse: `decode(<<malformed>>) == {:error, _}`** — the enforce-don't-
     coerce directive as a failing-then-passing test from commit 1; the over-long-
     bytestring split is literally a unit test.
   - header hash of known Preview header matches.
2. **Protocol FSM tests (CSP-fidelity).** The chain-sync `:gen_statem` is a pure
   transition function — feed a message, assert next state + output, no real
   socket. Tested against a mock-channel test process. Directly checks CSP
   conformance (matches `ChainSyncClientPeer_StCanAwait` etc.).
3. **Integration tests.**
   - **simulated peer** (test process speaking the wire back at us): full
     handshake→keepalive→chainsync, deterministic, fast, in CI. Bulk of
     protocol-correctness lives here.
   - **real Preview**: live, non-deterministic → `@tag :live`, EXCLUDED from the
     normal suite, run manually. CI never depends on Preview being up.

**Injectable `Channel` behaviour** is the seam TDD forces (and it's good): FSMs
talk to a `Channel` behaviour, never `:gen_tcp` directly — real socket in prod, a
test process in tests. Matches the CSP's `Channel` abstraction (CSP ~131-135), so
it's CSP-faithful AND testable for the same reason.

Deps: `ExUnit` (built-in) + **`StreamData`** (property tests — ideal for codecs:
"∀ valid SDU, encode∘decode = id"; "∀ bytes, decode never raises, only ok/error"
— natural fit for strict parsing). `Mox` later only if channel injection grows.

## Build strategy: trust-everything skeleton FIRST (validation stubbed)

The first build is a **trust-everything observer skeleton**: absorb blocks,
trust them all, `validate(block) → :ok`, ledger state is a toy dict, no SQL. This
deliberately exercises the **novel, unproven part** — the network/consensus model
expressed natively on the BEAM (forest, pointer, file-don't-chase, concurrent
peers, rollback-as-pointer-movement) — and stubs the **well-understood,
already-staffed** parts (ledger/Plutus validation, Leios EB voting/signing).
"See what explodes" early, cheaply, in the concurrency rather than in design.

The seam is clean: validation is a behaviour (`:ok` now, real later); the toy and
spec-faithful ledgers are two modules behind one boundary. Nothing here is torn
out later — real validators slot into the same seam. (Defer the work, not the
affordance.)

**Trust assumption (RECORDED, not hidden) — the spec-discipline version of a
stub.** The skeleton's correctness rests on: *we follow the honest majority and
assume what the network converges on is valid; we do not verify.* Consequences,
which are FINE for the skeleton and must not be forgotten later:

- The "network validates for me" property is **eventual and
  honest-majority-conditional**, NOT instantaneous or adversary-proof. A
  malicious/buggy peer can feed a fork built on an invalid block; our forest holds
  it as a live candidate and, if transiently longest, **our pointer will select
  it** until honest weight overtakes it. A real node rejects it at Door 1 and
  never selects it; the skeleton selects it and rolls back on convergence.
- So a trust-everything node is observationally **a node that treats every
  received block as if it passed Door 1.** Its instantaneous tip may be invalid;
  it self-corrects only by convergence. This actually **stresses the rollback
  machinery harder** (more forks survive longer) — a *better* concurrency
  test-bed. The hazard is only if we later forget the tip was never validated and
  trust it for something real.

**CRITICAL distinction — trust the blocks, STILL CHOOSE between them.**
Trust-everything stubs **validation** (`:ok`), but **chain SELECTION** is
consensus logic, not validation, and it drives the pointer that is the whole
point of the skeleton. Keep a real-ish selection rule (even toy: longest wins,
tie-break by id). Do NOT accidentally stub selection — without it there is no
pointer movement to test. Validation stubbed; selection real.

## Methodology: spec-driven, test-first

The project is built **test-first (TDD)** against the **Agda formal Cardano
specification** wherever possible. The Agda spec — not the Haskell node, not
folklore — is the source of truth for ledger and consensus rules.

- Each ledger/consensus rule is implemented only after a failing test that
  encodes it, and that test **cites the spec rule** it represents (the Agda
  relation, figure, or section).
- A reader should be able to trace **test → spec rule → implementation**.
- This is exactly why the pure/effectful boundary (below) is kept a hard line:
  the pure core is directly spec-testable with no process scaffolding, which is
  what makes spec-driven TDD practical here.

## The three concerns (Cardano's own division)

| Concern | Nature | On the BEAM |
|---|---|---|
| **Ledger** | pure | plain modules: `applyTx`, `applyBlock`, UTxO rules, validation |
| **Consensus** | mostly pure | chain selection, header validation, mini-protocol *logic* |
| **Network** | effectful | sockets (later), the mini-protocols on the wire, peers, timeouts |

The single most important discipline: **the pure/effectful boundary is a hard
line.** Pure modules never call a process, read the clock, or do I/O. Time,
randomness, and current state are passed in as arguments. This is what makes
the ledger and consensus testable in isolation, and it is the boundary most
easily eroded later — so we commit to it now.

## What is a process vs. a pure module

| Concern | BEAM shape | Why |
|---|---|---|
| Ledger rules | pure modules (`Cardamom.Ledger.*`) | deterministic, no state |
| Chain selection | pure functions | it's `prefer`/`compare` on chains |
| Mempool logic | pure module | a fold over txs |
| ChainStore | `GenServer` (+ children) | owns state; see below |
| Each mini-protocol instance | `:gen_statem`, one per (peer, protocol) | protocols *are* typed state machines; agency = state |
| Each peer | a small supervision subtree | connection + its client protocol FSMs |
| Peer manager | `DynamicSupervisor` + registry | peers come and go |

We map **one `:gen_statem` per (peer, protocol)** because the Ouroboros
mini-protocols literally *are* state machines with agency. The on-the-wire
multiplexing of several protocols over one connection is treated as a separate
concern, not folded into the protocol FSMs.

### Concurrency model: concurrent gather, sequential commit

On the BEAM, concurrency is native: one process per (peer, protocol),
preemptively scheduled, isolated, communicating by message-passing. We model the
mini-protocols as independent processes directly, rather than coordinating them
within a single runtime thread.

So we **fan out** the I/O-bound, order-independent work and **funnel** the
order-dependent work:

- **Concurrent (N peer processes, fully parallel):** connecting, downloading
  headers/bodies, deserialising, *stateless* validation (signatures, structure).
  This is ~95% of wall-clock time and parallelises beautifully. Each peer
  follows its own peer's chain and gathers candidate headers/blocks.
- **Sequential (one serialisation point):** the `apply_block` fold into ledger
  state. A fold is inherently sequential — `apply_block(state, N+1)` depends on
  the state from block N. Two peers must **not** fold concurrently: that races
  the fold and yields a state corresponding to *no* valid linear history, and is
  nondeterministic (which would destroy spec-testability). The single
  ledger/coordinator process's **mailbox is the linearisation** — no locks
  needed, just "send the candidate to the one process that owns the fold."

```
N peer processes (per peer, per protocol)   ← wildly concurrent: fetch,
   │  follow their peer's chain, gather         deserialise, stateless-validate
   │  candidate headers/blocks
   ▼
Consensus.Coordinator (+ ledger process)     ← ONE serialisation point:
   - chain selection across peers' claims        chain selection + apply_block
   - the apply_block fold (sequential, in-order) fold, deterministic
   - owns ETS ledger state
```

The "nebulous land of not-yet-synced stuff" — peers at different tips, some on
forks, some lagging — is **not a bug to engineer away; it is the problem the
consensus layer exists to solve.** We collect concurrent, possibly-conflicting
claims and let chain selection resolve them to one ordered history. Distributed
system on the way in; linear, deterministic history at the commit. The sequential
fold is sequential because the *semantics* are sequential, not because of any
runtime limitation.

## Storage — chain DATA vs. ledger STATE (two different things)

The single most important storage insight: **chain data and ledger state are
not the same thing and must not share a store.**

- **Chain data** — blocks and the txs inside them. Immutable, append-only,
  ever-growing (~150–200 GB). The **source of truth**. This is the *log*.
- **Ledger state** — the current UTxO set (+ stake/reward/governance
  accounting). Mutable, bounded (~GBs), and itself **derived** by folding every
  block over genesis: `ledger_state = foldl(apply_block, genesis, chain_data)`.

State is a *projection of* data. They want different homes:

| Concern | Store | Cache? |
|---|---|---|
| **Ledger state** (UTxO set, etc.) | **ETS**, owned, authoritative in-memory | **No** — never evict; it's a source of truth, not a cache of SQL |
| **Chain data, durable** | append-only log (truth) + **SQLite/Ecto** index | — |
| **Chain data, hot working set** | **Nebulex** (ETS Local adapter) over the log/SQL | **Yes** — recency-hot, multi-reader, evictable |

### Why Nebulex for chain data but NOT for ledger state

This distinction is deliberate and was hard-won:

- **Ledger state is not a cache.** There is nothing to read through to (it's the
  authoritative in-memory copy, itself rebuildable only by replaying the whole
  log) and it must **never** be evicted — dropping a UTxO would corrupt
  validation. So no cache library; the owning process holds it in ETS directly.
- **Chain data's hot working set IS a cache.** Recent blocks/txs are read
  constantly by *many concurrent processes* (every peer FSM, the coordinator,
  the indexer, you). That's a textbook read-through cache over a backing store,
  hot on recency, where **eviction is correct** — an evicted old block is still
  in the log/SQL and is re-fetched transparently on miss. On the BEAM these
  reads come from dozens of independent processes at once, so a shared
  ETS-backed cache (Nebulex Local adapter) serving them lock-free is exactly
  right, and we get generational GC / max-memory eviction for free rather than
  hand-rolling it. Keyed by block/tx hash; read-through to log/SQL on miss.

### The owning process

There is **one `ChainStore` process** coordinating the durable side. Everything
that needs the durable chain talks to it (the hot cache is a shared Nebulex
cache read directly by many processes).

```
ChainStore (GenServer) ── owns the durable side
   ├── ChainStore.SqlWriter (GenServer)   ← async casts, batches,
   │      └── Ecto / SQLite                   writes in transactions
   └── ChainStore.Log                      ← append-only raw store (source of truth)

Ledger state ── ETS, owned by the ledger/coordinator process (NOT a cache)
Chain-data hot set ── Nebulex Local (shared ETS cache), read-through to log/SQL
```

Design properties, chosen deliberately:

- **Ledger-state reads (ETS) are instant and always current.** The validation
  hot path (`is this UTxO live?`) never touches SQL or the cache.
- **SQL writes are async and the SQL view *trails* the live state.** A feature —
  it keeps the node fast. Only the analytical SQL view is eventually-consistent;
  the ledger state (ETS) is not.
- **The raw log is the source of truth.** Both the SQL index and the ledger
  state are *derived* and rebuildable by replaying the log.
- **ETS ownership matters.** Ledger-state and durable tables are owned by
  long-lived processes (table heirs), so a worker crash never loses authoritative
  state. (ETS tables die with their owner — the classic BEAM gotcha.)

### Guiding stance: belief is "forest + pointer", and eventual consistency is the POINT

The node's belief about the chain is: **a forest of candidate extensions over an
immutable base, plus a pointer to the currently-selected tip.** Messages arriving
and validations completing are just events that **prune branches and slide the
pointer** (forward, or backward then down another branch on a rollback). The
structure is *always* "kinda-sorta up to date" — and **this is not a defect to
resolve, it is the correct steady state.**

Why this is right, not merely convenient: consensus is *emergent, not negotiated*
(see below), so there is **no global moment of truth to be in sync with.** Every
node is permanently kinda-sorta-up-to-date relative to every other — the protocol
*assumes* it. A node whose internal model is also permanently
kinda-sorta-up-to-date is therefore the *only* model that matches the domain. We
lean into eventual consistency rather than forcing a single globally-resolved
state, which is what the BEAM's process model makes natural.

**"Pointer" is load-bearing.** The committed base, the diffs, the folding don't
*move* when belief changes. Changing your mind = moving a pointer to a different
leaf. A **rollback = move the pointer back and down another branch** — not undo/
redo of state, just *re-selecting* which already-present candidate path is
"current". Belief-change is pointer-movement over a structure that already holds
all live hypotheses. Cheap, reversible, no panic. The thing Haskell nodes treat
as a fraught special case (rollback) is here just normal operation run backwards.

**The boundary that keeps the relaxation SAFE, not naive.** Eventual consistency
has a precise scope:

- *Eventually-consistent (lean in fully):* **which tip is selected** (can lag,
  flip, roll back); **the forest's completeness** (missing parents, unconnected
  fragments); **the analytical/forensic SQL view** (trails by design).
- *Immediately-consistent (the floor — NOT relaxed):* **the committed base below
  `k`** (once folded it is not a hypothesis and not revisable — relaxation lives
  *above* the security parameter; `k` is exactly "the eventuality has already
  happened here"); **the fold's determinism** (given a *chosen* branch, the
  ledger state at its tip is a pure function of (base, that branch in order)).

So: **relaxed about *which hypothesis is current* and *how complete the picture
is*; exact about *what each hypothesis means* and *what has settled below `k`*.**
Eventual consistency on *selection + completeness*; strict determinism on
*interpretation + settlement*.

**There is NO concurrency hazard here at all** (final position, after Ramsay
dissolved a series of phantom hazards I introduced, 2026-06-08):

- **Intra-chain ordering cannot be raced.** A block references its parent by
  hash; it is *unapplicable* until the parent's state exists. "Apply B then A"
  is impossible — the chain is self-ordering, the parent-hash *is* the ordering
  constraint, baked into the data.
- **"Two folds against the same parent state" is not a hazard — it is the
  DEFINITION of a fork**, and forks are exactly what we maintain independently.
  Two children of one parent produce `S ⊕ diff_A` and `S ⊕ diff_B` over the
  **immutable** base S: two distinct branch states, two leaves, both kept,
  *writing to different places (their own diffs)*. Nothing is contended. This is
  just "instances of the same thing" again — same-parent forks are ordinary
  branches, requiring **zero coordination**. Embarrassingly parallel.
- The phantom hazard only ever appeared if you imagine a **single mutable current
  ledger state** that blocks mutate — the very thing the forest + pointer +
  immutable-base model abolishes. Once state = "immutable base + a diff per
  branch", same-parent forks are the most natural thing in the world.

**Even base-promotion is not a "serialization point" — it is single-writer by
NATURE.** Promotion (fold a now-stable block into the immutable base) is done by
the *selected* chain only, and there is exactly **one base and one pointer**, so
there is inherently **one writer of the base** — not because we impose a lock,
but because there is one base and one selected chain feeding it. One process owns
"base + pointer" the way all OTP state has an owner: a datum with an owner, not a
defended critical section.

So the whole "concurrency control" question dissolves:
- **Forks (incl. same-parent) = independent branches**, diffs over a frozen base.
  Zero coordination. Parallel.
- **base + pointer = one authoritative datum, one natural owner.** Not a lock,
  not a serialization-as-defense — just OTP state ownership.
- **No race anywhere**: forks write their own diffs; the base has one writer
  because there is one selected chain.

Architectural payoff: the coordinator is just {ingest candidates file-don't-chase;
diff-compute branches in parallel (immutable base, no coordination); run selection
to maybe move the pointer; advance the base when the selected chain's block sinks
below `k`}. No global lock, no STM barrier, no "resolve my state" moment, and —
importantly — no serialization point we have to *engineer*; single-writer-of-base
falls out of there being one base.

### The volatile candidate forest and its three exits

Out-of-order arrival, honest slot battles, and malicious blocks are **not three
problems** — they are one structure: a **forest of candidate blocks**, keyed by
hash, indexed by parent, anchored on the immutable committed base, differing only
in *why* and *when* each candidate leaves.

- **Fragments coalesce on arrival (file, don't chase).** Block B arriving with
  parent A (not yet seen) is filed under "waiting on A". When A arrives — from
  *any* peer — they connect. No process ever blocks waiting for or actively
  fetches a parent. The union of N peers' (individually-ordered) chain-sync
  streams is *not* ordered, so missing-parent is normal, not an error.

A candidate's lifecycle has exactly three outcomes — but note (per the
forest+pointer thesis) we **do NOT vicious-prune valid forks**. Valid candidates
*retain* and evict by cache pressure, so the pointer can always roll back onto
any branch still resident.

1. **Promoted** — on the selected chain and now deeper than `k`: folded into the
   immutable committed ledger state. Leaves the forest *upward, into truth*
   (promotion, not eviction).
2. **Refused at the door (NOT pruned)** — a block failing the **cheap
   context-free check** (invalid VRF / signature → provable garbage) is **never
   admitted to the forest at all.** This isn't pruning-for-tidiness; it's
   *non-admission* — it was never a candidate. Only a **forensic tombstone**
   persists ("Peer 7 sent garbage at slot N"), never the block in the live
   forest. **Door 1.**
3. **Retained, then forgotten by cache pressure** — every *valid* candidate
   (winner, loser, slot-battle loser, abandoned-but-valid branch) simply **lives
   in the cache-fronted forest** and ages out by eviction when cold/old/below the
   retention horizon. **No verdict, no active deletion.** The pointer roams
   freely over whatever is resident. **Door 2.**

**Why Door 1 is non-admission, not pruning — and why it's REQUIRED to make
retention safe.** A "let it all just exist in the cache" store is *unbounded
against an adversary* who cheaply generates infinite invalid blocks and keeps
them hot by spamming — eviction pressure can't reclaim faster than they produce.
So the cheap gate is not tidiness; it is the **bound** that makes unbounded
retention of *valid* candidates safe. Refuse provable garbage at the door; be as
retentive and relaxed as you like about everything that passes. (Resolves the
tension: vicious pruning would destroy the branches rollback needs; non-admission
of garbage destroys nothing that was ever a candidate.)

**Eviction never means lost — the log is the rollback backstop.** Because the
forest is cache-fronted over the durable log, an evicted valid branch still has
its bytes in the log. A rollback to a branch the cache has dropped is a **cache
miss → read-through to the log → re-materialise the branch** — slow, not
impossible. The pointer can roll back as far as the *log* holds (not merely as
far as the *cache* holds). This is the cache-front earning its keep: hot working
set of candidates in cache, "everything valid we ever saw" in the log.

**Validity is judged at two times.** Cheap context-free validity (VRF/sig) on
arrival — the Byzantine gate / Door-1 non-admission. Full ledger validity (do its
inputs exist in the UTxO set at its position?) is a *fold* and is only paid
**if/when the branch is folded** — i.e. only on the branch the pointer actually
commits. Retained losing forks (Door 2) are never folded, so they never pay for
expensive ledger validation; they just sit in the cache and age out. So: provable
garbage refused cheaply at the door; valid losers retained-then-evicted
un-folded; only the committed branch pays full ledger validation.

**Note on slot-battle losers:** these are *valid* blocks that simply lost the
Praos tie-break — they are **Door 2 (retained, valid)**, NOT Door 1. The pointer
just doesn't select them; they stay resident so it *could* flip back if weight
shifts, and evict by coldness. Only *provably invalid* blocks (bad VRF/sig) are
Door-1 refused.

### Storage of the candidate forest: Nebulex (and it passes the cacheability test)

The volatile candidate forest **is** cacheable — and this does *not* contradict
"ledger state is never a cache". A Door-2 candidate is, by definition, harmless
to evict (that's what "lost relevance" means); if it could still matter it's
within `k` and recency/weight policy keeps it; if it ever mattered again it's
re-received from a peer (read-through on miss). So the forest fits **Nebulex**
(ETS-backed, recency/relevance eviction). The *committed* ledger state still
fails the test and is never cached. (Rule holds: cacheable iff eviction is
harmless — the committed state isn't, the volatile forest is.)

### Forensic store: recording closed forks (write-only from the node's view)

We want closed forks to *persist* — to come back in a year and explore "that time
Block F was all lies and how we handled it". This is **NOT** done by giving
Nebulex a SQL backing (that mechanism is *cache coherence* — reload live entries
on miss — the wrong lifecycle). Instead, **eviction/closure is the seam**: at the
moment a candidate leaves via Door 1 or Door 2, emit a **lifecycle event** to the
existing trailing SQL writer, recording what the cache *can't* (it's a property of
the event, not the block):

- **why** it closed (invalid VRF / failed ledger validation / lost slot battle
  *to which competitor* / aged out below `k`),
- **who** sent it (peer — enabling "everything else Peer 7 ever sent"),
- **when**, at what tip/height relative to the eventual winner,
- the **competing branch** that beat it — so the *contest* is reconstructable,
  not just the loser.

This is the same SQLite/Ecto analytical store already planned, gaining a
`fork_closures` / `candidate_lifecycle` table. No new infrastructure — the
trailing writer already exists; we add event *types*. Nebulex stays purely the
live-candidate cache and needs **no** SQL backing.

**Constraint — forensic store is write-only from the node's perspective.** A
spec-conformant node's correctness does not depend on remembering dropped forks;
they are *meant* to leave no trace. Recording them makes Cardamom an *instrument*
whose observable behaviour is a superset of a conformant node's — fine, but the
consensus logic must **never read the forensic store back**, or chain selection
would depend on history a real node cannot see, diverging from the spec in a way
that matters. Write-only to the node; read-only to us. (Same discipline as "SQL
view trails, ledger never reads it back.")

### Ledger state is itself two-natured (open exploration)

A pure UTxO model makes "state" conceptually light: the set of unspent outputs,
updated per-tx by local set difference/union — no Ethereum-style global mutable
account map. **But** Cardano's ledger state is UTxO *plus* accumulated
non-local accounting: stake distribution, delegation/reward state, protocol
params + scheduled updates, governance (Conway). These have a **different update
rhythm**:

- **Light, per-tx, foldable:** the UTxO set. Hot ETS, set-surgery per tx.
- **Heavy, epoch-periodic, globally recomputed:** stake snapshot, reward
  distribution, pool retirement, param/governance enactment — done at the
  **epoch boundary**, not per tx.

So "the UTxO model is light" and "there's more to it" are *both* true: the model
is light and the accounting riding alongside it is not. Feeling exactly where
that line falls — and whether our chosen single era even includes multi-assets,
datums, etc. inside each output — is an explicit goal of building this, and a
likely source of spec questions. Not over-designed now; let spec + implementation
reveal the right split.

### Why SQLite, and why analysis is a first-class goal

Analysis tools and direct SQL querying are a stated goal, so SQL is designed in
from the start, not deferred. We use **Ecto + SQLite (`ecto_sqlite3`)**:
embedded, zero-ops, single file. Going to **Postgres** later (if analysis
outgrows SQLite) is an adapter + config change through Ecto, not a rewrite.

A node *itself* only needs sequential reads and keyed lookups — it never asks
"find all txs paying address A". That arbitrary-query job belongs to the
**analytical index** (our in-process equivalent of `cardano-db-sync`), populated
by a writer that *trails* the chain and is decoupled from validation.

## Relay-readiness: make the seams, don't fill them

We defer *serving* (relay/server side) but **must not write ourselves into a
corner** that requires a rewrite to add it later. Principle: **defer the work,
not the affordances.** A relay is an observer plus the *server halves of the same
protocols*, reading the *same stores* — it exposes outward what the observer
already computes inward. Test: *does everything a server would answer with
already exist, owned by a process a server could ask, without the observer having
privatised it?*

Three "leave the door open" moves now (each justified by something the observer
needs anyway or nearly so) — and explicitly **no speculative server building**:

1. **Protocol roles are dual, not separate.** Each mini-protocol is ONE state
   machine with two agencies (client/server are duals — same states/transitions,
   opposite agency). Factor the **protocol description** (states, message types,
   legal transitions) out of the client FSM, ideally as data, spec-derived. The
   client is "the FSM driving the agency we hold". The server later is the same
   transition table, other agency. *Caveat:* factor out the transition
   table/messages (low-risk, obviously dual, spec-derived); do NOT build a fully
   role-generic FSM driver against an imagined server — refactor to share the
   driver when the server actually exists to keep us honest. Over-abstracting
   against an imaginary second user is worse than a clean client refactored once.

2. **Stores are point-addressable, not just tip-forward.** A server answers
   "body for hash H" and "successor of point P". Build the ChainStore/log API as
   `get_block(hash)`, `successor(point)`, `tip()`, `stream_from(point)` from the
   start — most of which the observer's own client needs anyway (it rolls back to
   *points*). Don't let the API assume "I only move forward from my own tip".
   (Data is already all-by-hash in the log; this is just not hiding it behind a
   too-narrow API.)

3. **Peer sessions are dial-agnostic; the inbound seam exists empty.** A peer
   session = a connection + its protocol FSMs, agnostic to who dialed whom.
   Outbound (observer) and inbound (relay) differ only in how the connection was
   established and which agencies we hold. Put the `DynamicSupervisor` of peer
   sessions in place now (observer fills it with outbound sessions); the inbound
   listener/acceptor is a SIBLING added later, attaching to the *same*
   supervisor. Build the supervisor, not the listener.

Explicitly NOT now: listening socket / acceptor; server-side FSM
implementations; outbound advertisement + rollback-to-followers; the "which
abandoned forks stay servable" policy (still deferred, constrains nothing now).

## No reject-gossip; consensus is emergent, not negotiated

Ouroboros (Praos) is **Nakamoto-style, not BFT voting.** There are NO vote
messages and NO reject messages — that category does not exist in the protocol.

- A node only ever **advertises its own currently-selected chain** (chain-sync:
  "roll forward to this header" / "roll back to point P"). It never tells anyone
  what it rejected — a dropped fork simply stops being advertised, and
  `rollBackward` implicitly tells downstream followers "abandon what you got from
  me past P". Rejection is the *absence* of advertisement + a rollback, never a
  stated verdict.
- Each node decides **locally and independently** which chain is best by the same
  deterministic rule (longest/densest, VRF tie-break). Agreement is *emergent*
  from identical local rules over shared data, not negotiated. The chain *being
  longer* is the message; consensus is implicit in the data.

Design consequences:
- The network layer never gossips verdicts. Candidate-forest Door-1/Door-2
  closures are **purely local bookkeeping** — we never tell a peer "ABC was lies".
- `rollBackward` to downstream followers (server side, later) is the *entire*
  "I changed my mind" surface. It is not a rejection message — it's "rewind to P,
  follow my new tip".
- The **forensic store is even more clearly instrument-only**: *why* a fork died
  exists NOWHERE in the network (no peer knows, no message carries it). Cardamom
  captures what the protocol structurally discards. Reinforces write-only-to-node.
- **Naming:** the local arbiter applies the selection rule + folds; it does NOT
  negotiate. Avoid "Consensus.Coordinator" implying negotiation — prefer
  `ChainSelection` / a ChainDB-side arbiter. (To finalise with the tree.)

SPEC CHECK (Ramsay's domain — verify, don't assert from memory): the precise
density/length rule, and **Praos longest-chain vs. Genesis density-window rule**
(Genesis resists a long adversarial chain shown to a fresh/eclipsed node — which
rule is normative for which sync situation?); and the exact same-slot tie-break
(believed VRF-lowest). Cite the formal spec.

## Supervision tree (sketch — to be finalised)

```
Cardamom.Application
└── Cardamom.Supervisor (top)
    ├── ChainStore (GenServer)
    │   ├── ChainStore.SqlWriter
    │   └── ChainStore.Log
    ├── Consensus.Coordinator        (chain selection across peers)
    └── Network.Supervisor
        └── (DynamicSupervisor) per-peer subtrees
            └── Peer.Supervisor
                ├── Peer.Connection
                ├── MiniProtocol.ChainSync   (:gen_statem, client)
                └── MiniProtocol.BlockFetch   (:gen_statem, client)
```

Supervision mirrors **failure domains**: a peer dying must not touch the
ChainStore; the SqlWriter restarting must not drop live ledger state.

## Open questions

- Final supervision tree shape (above is a sketch).
- Module/namespace layout.
- Exact simplified-ledger rules for the chosen era.
- Where the future codec seam sits precisely.
