# Cardamom — guidance for Claude (and other AI assistants)

Public working guidance for anyone (human or AI) contributing to Cardamom. For
the architecture rationale see `architecture.md`; for the specification
landscape see `network-specs.md`; for the byte-level wire guide see `WIRE.md`;
for working notes and findings see `wire-protocol.md`; for security invariants
see `security.md`; for testing methodology see `../test/TEST_STRATEGY.md`.

## What Cardamom is

A Cardano node reimplemented on the BEAM (Erlang VM) in Elixir. Near-term it is a
**chain-following observer**: it connects to the Cardano **Preview testnet**,
follows the chain via the Ouroboros mini-protocols, and exposes what it sees for
observation and query. It is built to map Cardano's pure/effectful split onto
OTP: pure modules for ledger/consensus logic, processes (`GenServer`/
`:gen_statem`) for the concurrent network and state machinery.

## Working principles

**Spec-driven, test-first.** Implement ledger/consensus rules against the Agda
formal specification and protocol behaviour against the formal/CDDL sources;
write the test first, and cite the spec rule (file + location) the test encodes.
Do not assert spec or protocol detail from memory — verify against the actual
spec/CDDL/source. Where a spec or its documentation is unclear, incomplete, or
surprising, raise it explicitly rather than guessing.

**Strict parsing — enforce, never coerce.** Decoders enforce the grammar exactly:
a field that doesn't fit is an error, not something to trim or normalise. Liberal
("be generous in what you accept") parsing is unsafe in a consensus system —
different lenient interpretations can diverge. Test the reject paths, not just the
happy path (see the MC/DC-style corner tests in the codec test suites).

**Structural fidelity to the formal protocol model.** Mini-protocol state
machines mirror the formal model's process structure (the CSP-style Agda
ITree-CSP model in `input-output-hk/agda-cardano-common`, branch
`kangfeng/itree-csp` — see `network-specs.md` §2.1): one `:gen_statem` per
protocol, state names matching the model's states, branches ordered as the
model's choices, and the relevant model location cited per state. Send-last then transition to a receiving state.
External choice ⟺ a guarded receive; a decision the node makes (internal choice)
is factored into a separate driver process that messages the FSM. If a state's
structure can't be expressed this way, raise it rather than forcing it.

**Security: a Harvard boundary between code and data.** Network/untrusted input
becomes **inert data only** (integers, binaries, lists, fixed-key maps) — never a
module name, dispatch target, or code-selecting atom. The `{module, handle}`
dispatch pair is always the first parameter and the module must be statically
determinable (set in our code, never from the wire). Banned on untrusted input:
`binary_to_term`, `to_atom`/`binary_to_atom` on received content, and
`apply`/`mod.f` with a non-literal module. Map received selectors with explicit
static matches, never a data-derived atom. See `security.md`.

**Observe, don't drive.** Read-only surfaces (the web UI, introspection, the peer
registry) observe node state through clean read-only seams; they never reach into
process internals or steer the node. The node observes the network; it does not
experiment on it.

## Conventions

- Behaviours with injectable implementations for I/O seams (`Channel`,
  `PeerStore`): a real implementation for production, an in-memory/test
  implementation as the test default. Tests never touch real I/O or real
  persistence.
- Telemetry (`:telemetry`) is the single event spine; logs, observation storage,
  and the UI all subscribe to it.
- Run `mix test` (fast, deterministic, no network). Coverage via
  `mix coveralls.html`; treat statement coverage as a "is this code run at all"
  backstop, not as test adequacy — favour targeted tests of decision/branch
  corners.

## Scope guardrails

- **Preview testnet only.** Connecting to mainnet is refused structurally
  (`Cardamom.Network`).
- **Read-only / consumer roles only.** We consume chain-sync, block-fetch and
  keep-alive, and we *receive* tx-submission gossip and peer-sharing replies
  for observation. The bright line: anything that **propagates or submits** a
  transaction, or **accepts inbound connections**, is out of scope without an
  explicit, deliberate decision — never "just to test it".
