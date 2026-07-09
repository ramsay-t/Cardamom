# Cardamom Test Strategy

Cardamom is a wire-compatible Cardano chain follower. It parses adversarial, permissively-encoded
data (CBOR that accepts wrong field layouts), tracks consensus- and ledger-level state with many
decision branches, and must *reject* malformed or invalid input as reliably as it accepts valid
input. In that setting, "it compiles and the happy path passes" is not evidence of correctness.
Every expensive bug this project has hit lived on a *rejection* or *edge* branch that a happy-path
test never exercised: the collateral-return index, the indefinite-array framing, the
cursor-set-versus-reorg rollback, the un-spend-on-re-extract, the missing `decode_inputs`
set-tag clause. This document states how we test so those branches are not left untested.

## Principles

The strategy is layered. Each layer is necessary; none is sufficient alone.

### 1. Spec-driven TDD

Tests are written against the authoritative Cardano specifications — the Agda formal ledger and
Praos specs, and the CDDL — not against our own assumptions. A test that encodes a rule cites the
rule it encodes (spec file, section, or rule name) in a comment. The specification, never the
implementation, is the oracle. This is doubly important because our decoders are *permissive
observers*, not validators: CBOR will happily decode a wrong layout, so only agreement with the
spec (and with real bytes, below) demonstrates correctness.

### 2. Real captured bytes are the gold standard

Wherever possible a test decodes or checks a **real captured Preview block** (see
`test/fixtures/`), not a synthetic construction. Because the wire encoding is permissive, only real
bytes prove that our interpretation matches what the network actually produces. The block-body hash
verified against a real block, the invalid-transaction collateral return read from real block
52578, the operational-certificate signature checked against a real header — these are conformance
vectors, not illustrations.

Where a real fixture cannot express the case under test (many distinct linked headers, a
deliberately invalid signature, a synthetic reorg), we build synthetic input — but *structurally
real* synthetic input: builders produce genuinely valid structures (for example, the header builder
signs operational certificates with a real Ed25519 key so a synthetic header passes the real
validation gate), never a shape that only our own decoder would accept.

### 3. Rejection-side first

The correctness and security value of this system is concentrated in its *failing* paths: an
invalid header dropped before it reaches the store and its sending peer's reputation docked; a
tampered operational certificate rejected with every signed field flipped independently; a
value-conservation divergence flagged. Tests must demonstrate that bad input is **rejected**, not
merely that good input is accepted. When a decision distinguishes valid from invalid, the invalid
side is the more important test.

### 4. Round-trip / invertibility for reversible logic

For any operation with an inverse — chain rollback, the invertible ledger-state delta journal — the
test applies the operation and then its inverse and asserts the state is *identical* to before, at
the byte level where practical. This class of test found the ledger-delta bugs where a deposit was
modelled as an accumulator rather than a create/remove, and where a set-to-absent left a lingering
null row.

### 5. Statement coverage is a backstop, not a goal

We run `mix coveralls` (ExCoveralls) to *find lines that are never executed*. Statement coverage
answers only "is this code run at all." It is cheap, it catches dead defensive arms and unreachable
fallbacks, and it is a floor — not a measure of test adequacy. A suite can reach 100% statement
coverage while the fault-relevant *combination* of conditions is never exercised. Coverage cannot
make any inference about code that *should be present but is not* — a missing catch-all clause is
invisible to it [1, §5.1].

### 6. MC/DC on pattern matching — the primary adequacy technique

Modified Condition/Decision Coverage (MC/DC) requires that each condition in a decision be shown to
independently affect the decision's outcome. In Erlang and Elixir most decisions are expressed not
as boolean expressions but as **pattern-match clauses**: a multi-clause function head, a `case`, a
`with`, a guard sequence. Statement coverage is blind to these — a whole clause (an entire decision
branch) can go unselected while every *line* is covered by other clauses, leaving a genuine branch
untested. This is exactly how the `decode_inputs` set-tag gap and the header-shape-dispatch cases
hide.

Our practice, following the extension of MC/DC to pattern matching in Smother [1]:

- For each multi-clause function, `case`, `with`, or guarded decision, **enumerate the clauses**
  and ensure a test drives **each clause independently** — including the catch-all / defensive
  clause, and the rejection clauses.
- Where a clause matches a *structure* (a tuple shape, a tagged map, a CBOR tag), test each distinct
  structural alternative separately; a clause never selected is untested even at full statement
  coverage.
- For guards with several conditions, falsify **each condition independently** (the "one field
  invalid, others valid" cases) so each is shown to independently drive the rejection.

We do not run Smother itself here (it targets Erlang; Cardamom is Elixir). Instead the MC/DC
analysis is performed **by reading the code and reasoning about which clause each test selects**,
then adding a test per uncovered clause. This is a manual application of the paper's method, and
tests that do it say so — search the suite for `MC/DC` to see the convention in use (for example,
the `unwrap_header/1` alternate-envelope block in `connection_header_test.exs`, the codec catch-all
tests, and the handshake guard-falsification tests).

## Workflow for "improve coverage"

1. Run `mix coveralls` (or `mix coveralls.html`) to find unexecuted lines — the backstop pass.
2. Perform the MC/DC pass: read each decision, add one test per unselected clause, including the
   rejection and catch-all clauses; falsify each guard condition independently.
3. Prefer a real fixture; where synthetic, keep it structurally real.
4. Assert the rejection path, not only the acceptance path.
5. For reversible logic, add the apply-then-invert round-trip.

## Reference

[1] R. Taylor and J. Derrick, "Smother: An MC/DC Analysis Tool for Erlang," in *Proc. 14th ACM
    SIGPLAN Workshop on Erlang (Erlang '15)*, 2015, doi: 10.1145/2804295.2804297.
    Source: https://github.com/ramsay-t/Smother
