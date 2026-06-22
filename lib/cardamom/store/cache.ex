defmodule Cardamom.Store.Cache do
  @moduledoc """
  The hot in-memory working set in front of the durable store (Nebulex, ETS-backed).
  Holds recently-touched headers/blocks/txs for fast point lookups; eviction is
  HARMLESS because the bytes still live in SQLite (a miss reads through and refills).
  This is NOT the source of truth — SQLite is.

  NOTE on coverage: this module is macro-only (`use Nebulex.Cache`), so the coverage
  tool attributes 0% — there are no hand-written runtime lines here; the generated
  put/get/delete bodies live in the dependency. The behaviour IS tested directly in
  `test/cardamom/store/cache_test.exs` and via ChainStore (100%). Marked
  coveralls-skip so the report doesn't flag a false gap.
  """
  # coveralls-ignore-start
  use Nebulex.Cache,
    otp_app: :cardamom,
    adapter: Nebulex.Adapters.Local

  # coveralls-ignore-stop
end
