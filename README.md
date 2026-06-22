# Cardamom

A [Cardano](https://cardano.org) node, reimplemented on the **BEAM** (Erlang VM)
in Elixir.

Cardamom maps Cardano's existing design — which already isolates pure
ledger/consensus functions behind a thin effectful shell — onto OTP:

- **Pure** modules (plain functions): header/block decoding, the candidate-chain
  forest and tip selection, codecs, hashing. No process, no clock, no I/O.
- **Concurrent** processes (`GenServer`): the Ouroboros mini-protocols
  (chain-sync, block-fetch, keep-alive), the per-peer connection bearer, the
  chain/forest server, and the durable store.

It is an **observer-focused** node: it connects outbound to a relay, follows the
chain, and retains data — it does not produce blocks or serve downstream peers
(yet). Three goals shape it: learn and demonstrate the network layer on the BEAM;
retain enough chain data to answer queries about current contract/ledger state;
and observe chain (and later mempool) flows.

## What works today

- **Handshake** with a relay (node-to-node v14), network magic guarded
  (mainnet refused).
- **Chain-sync** (protocol 2): follows the chain, decodes real Praos headers
  (15-field flat layout) and verifies their hashes, and **resumes from the stored
  tip** via `FindIntersect` rather than re-syncing from genesis.
- **Keep-alive** (protocol 8): so the relay does not reap the connection.
- **Block-fetch** (protocol 3): fetches block bodies **on demand**, decodes the
  Conway block, and **verifies the body against the header's `block_body_hash`**
  (the four-segment segwit hash) before storing — a tampered body is rejected.
- **Durable store**: SQLite (via Ecto) as the source of truth, fronted by an
  in-memory cache (Nebulex). Per-network DB file (`data/forest-<magic>.db`).
  Headers and blocks are kept verbatim (hash fidelity) alongside decoded columns.
- **Forest**: a candidate-chain forest tolerant of out-of-order arrival, forks
  and gaps, with incremental height/tip tracking.
- A read-only **HTTP UI** (hand-coded, no framework) showing the supervision
  tree, network topology, the forest, and a live protocol-event log.

Validation is **trust-everything** for now: blocks are decoded and their hashes
verified, but ledger/script validation is not yet performed. Block bodies are
fetched only on demand — the chain is followed at the header level; bodies are
retrieved when something asks for them.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — the forest+pointer model,
  storage design, concurrency model, and the observer→relay→producer progression.
- [`docs/wire-protocol.md`](docs/wire-protocol.md) — wire-format notes and
  findings against a real relay.
- [`docs/security.md`](docs/security.md) — the Harvard (code vs data) boundary
  and trust principles.

## Development

```sh
mix deps.get
mix test
```

The test suite runs against an in-process simulated peer and captured real-relay
fixtures; it does not require a live network connection. Tests are written
test-first and cite the formal Cardano specification for the rules they encode.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

Developed by Ramsay G Taylor, with AI assistance.
