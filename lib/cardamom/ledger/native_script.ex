defmodule Cardamom.Ledger.NativeScript do
  @moduledoc """
  Evaluate a NATIVE SCRIPT (Shelley multisig + Allegra timelock) against an environment — full
  validation of a real script class with ZERO Plutus (pure boolean/interval logic over the tree
  decoded by `Cardamom.Ledger.Conway.Witness`). Spec: Allegra `Timelock`/`evalTimelock`,
  Shelley `evalNativeMultiSigScript`.

  `satisfied?(script, env)` — env is `%{signers, lower, upper}`:
    * `signers` — MapSet of the tx's supplied vkey key-hashes (blake2b_224 of each witness vkey),
    * `lower`/`upper` — the tx's declared validity interval `[lower, upper)` (nil = unbounded).

  Leaves:
    * `{:sig, kh}`              — `kh ∈ signers`.
    * `{:all, ss}`             — all satisfied (∅ ⇒ true).
    * `{:any, ss}`             — any satisfied (∅ ⇒ false).
    * `{:n_of_k, n, ss}`       — ≥ n satisfied.
    * `{:invalid_before, s}`    — the tx's LOWER bound ≥ s (the tx is only accepted from s on).
      An unbounded lower ⇒ the bound can't be proven ⇒ NOT satisfied (fail-closed).
    * `{:invalid_hereafter, s}` — the tx's UPPER bound ≤ s. Unbounded upper ⇒ NOT satisfied.

  Timelocks check the TX's VALIDITY INTERVAL, not the block slot directly — the ledger separately
  enforces `slot ∈ interval` (see `Cardamom.Ledger.EconomicRules`); a timelock leaf constrains
  which intervals unlock the script. Unknown shapes are never satisfied (fail-closed — a script we
  can't understand must not be treated as unlocked).
  """

  @type env :: %{signers: MapSet.t(), lower: integer() | nil, upper: integer() | nil}

  @spec satisfied?(term(), env()) :: boolean()
  def satisfied?({:sig, kh}, %{signers: signers}) when is_binary(kh),
    do: MapSet.member?(signers, kh)

  def satisfied?({:all, scripts}, env) when is_list(scripts),
    do: Enum.all?(scripts, &satisfied?(&1, env))

  def satisfied?({:any, scripts}, env) when is_list(scripts),
    do: Enum.any?(scripts, &satisfied?(&1, env))

  def satisfied?({:n_of_k, n, scripts}, env) when is_integer(n) and is_list(scripts),
    do: Enum.count(scripts, &satisfied?(&1, env)) >= n

  # invalid_before s: the tx's lower bound must be present AND ≥ s.
  def satisfied?({:invalid_before, s}, %{lower: lower}) when is_integer(s),
    do: is_integer(lower) and lower >= s

  # invalid_hereafter s: the tx's upper bound must be present AND ≤ s.
  def satisfied?({:invalid_hereafter, s}, %{upper: upper}) when is_integer(s),
    do: is_integer(upper) and upper <= s

  # Anything else (incl. {:unknown, _}) — fail-closed.
  def satisfied?(_script, _env), do: false
end
