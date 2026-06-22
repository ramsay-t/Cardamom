# Cardamom

A [Cardano](https://cardano.org) node, reimplemented on the **BEAM** (Erlang VM) in Elixir.

The aim is to map Cardano's existing design — which already isolates pure
ledger/consensus functions behind a thin effectful shell — onto OTP:

- **Pure** modules (plain functions): ledger state transition, validation
  rules, mempool reapply/revalidate, header/chain selection.
- **Concurrent** processes (`GenServer`/`:gen_statem`): the Ouroboros
  mini-protocols (chain-sync, block-fetch, tx-submission), peer connection
  state machines, the mempool service, the chain DB.

Early days. Scope and fidelity (wire-compatible vs. semantic model) are still
being decided.

## Development

```sh
mix deps.get
mix test
```
