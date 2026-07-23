# Cardamom

A [Cardano](https://cardano.org) node, reimplemented on the **BEAM** (Erlang VM)
in Elixir.

Cardamom maps Cardano's existing design — which already isolates pure
ledger/consensus functions behind a thin effectful shell — onto OTP:

- **Pure** modules (plain functions): header/block/transaction decoding, the
  candidate-chain forest, the ledger rules and reward calculations, codecs,
  hashing. No process, no clock, no I/O.
- **Concurrent** processes (`GenServer`): the Ouroboros mini-protocols
  (chain-sync, block-fetch, tx-submission, keep-alive, peer-sharing), the
  per-peer connection bearer, the per-block/per-tx ingestion handlers, and the
  durable store.

It is an **observer-focused** node: it connects outbound to a relay, follows the
chain, and retains data — it does not produce blocks or serve downstream peers
(yet). Three goals shape it: learn and demonstrate the network layer on the
BEAM; retain enough chain data to answer queries about ledger state; and observe
chain and mempool flows.

## What works today

- **Live chain following** on the Preview testnet, running for months:
  handshake (node-to-node v14, mainnet structurally refused), pipelined
  chain-sync with resume-from-stored-tip, keep-alive, and automatic reconnect.
- **All-era decoding**: headers and blocks from Byron through Conway. Headers
  dispatch on their self-describing shape (15-field TPraos / 10-field Praos),
  are hash-verified, and pass a validation gate (operational-cert signature
  check) before storage.
- **Full block backfill**: bodies are proactively fetched back to genesis and
  verified against each header's `block_body_hash` commitment before storage —
  a tampered body is rejected. The full UTxO set is built and maintained.
- **Ledger state** (non-UTxO accounting) per the Conway formal (Agda)
  specification: certificate effects, withdrawals, deposits, fee pots, and the
  epoch boundary — stake snapshots and the full **reward engine** (exact
  rational arithmetic, spec rules cited per function). Every per-block effect
  is journalled as an invertible delta, so rollback works — including across
  an epoch boundary.
- **A block validation gate**: on-chain conformance rules (value conservation,
  the withdrawal-equals-derived-balance oracle) render an accept/reject
  verdict per block *before* derived state commits. As an observer following
  the real chain, a reject is treated as an assertion failure — it means our
  derivation is wrong (or we've found a specification issue), and the block
  parks unprocessed until we fix it.
- **Mempool observation**: the tx-submission client receives transaction
  gossip; pending transactions and their lifecycle (confirmed, rejected,
  expired, out-competed) are recorded.
- **Durable store**: SQLite (via Ecto) as the source of truth, fronted by an
  in-memory cache (Nebulex). Per-network DB file (`data/forest-<magic>.db`).
  Headers and blocks are kept verbatim (hash fidelity) alongside decoded
  columns, so everything is SQL-queryable.
- A candidate-chain **forest** tolerant of out-of-order arrival, forks and
  gaps; a read-only **HTTP UI** (hand-coded, no framework) showing the
  supervision tree, the forest, VM stats, and a live protocol-event log.

Not yet done (deliberate, staged): script (Plutus) execution, KES/VRF header
verification, the governance half of the epoch rules, and chain selection
between competing peers (we currently follow one relay). Validation grows
outward from conformance checking rather than being bolted on at the end.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — the forest+pointer model,
  storage design, concurrency model, and the observer→relay→producer
  progression (design rationale, with status notes where reality has moved).
- [`docs/network-specs.md`](docs/network-specs.md) — **the spec landscape**:
  every specification artifact needed to implement a Cardano network layer,
  what each covers, and where the gaps are.
- [`docs/WIRE.md`](docs/WIRE.md) — **the wire, byte by byte**: an observer's
  guide to the node-to-node protocols, era envelopes, header/block/tx
  encodings, and the gotchas — every claim pinned to a captured fixture and a
  test where one exists.
- [`docs/wire-protocol.md`](docs/wire-protocol.md) — working notes and findings
  from building against a real relay (the deep-dive companion to the two
  above).
- [`docs/security.md`](docs/security.md) — the Harvard (code vs data) boundary
  and trust principles.
- [`test/TEST_STRATEGY.md`](test/TEST_STRATEGY.md) — the testing methodology
  (spec-driven TDD, real-byte fixtures, rejection-first, coverage stance).

## Development

```sh
mix deps.get
mix test
```

The test suite (600+ tests and properties) runs against an in-process simulated
peer and captured real-relay fixtures; it does not require a live network
connection. Tests are written test-first and cite the formal Cardano
specification rule they encode.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

Developed by Ramsay G Taylor, with AI assistance.
