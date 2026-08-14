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

  @doc """
  The native-script HASH used as its script credential: `blake2b_224(0x00 ‖ CBOR(script))`, where
  `0x00` is the Shelley native-script language tag (`nativeMultiSigTag = "\\00"`, cardano-ledger
  Shelley/Scripts.hs). Re-encodes the decoded tuple tree to its CDDL array form.

  CAVEAT (verify against real data): this hashes a RE-ENCODING of the decoded tree, not the
  original received script bytes. It matches the on-chain script hash only if our re-encode is
  byte-identical to the wire form — true for canonical CBOR of these small fixed shapes, but
  CONFIRM on real script-locked inputs (a mismatch means we must carry raw script spans instead).
  """
  @spec hash(term()) :: <<_::224>>
  def hash(script), do: Cardamom.Crypto.blake2b_224(<<0x00, encode(script)::binary>>)

  # Re-encode a decoded native script to its CDDL array (inverse of Witness.native/1).
  defp encode({:sig, kh}), do: CBOR.encode([0, %CBOR.Tag{tag: :bytes, value: kh}])
  defp encode({:all, ss}), do: CBOR.encode([1, Enum.map(ss, &decoded_to_term/1)])
  defp encode({:any, ss}), do: CBOR.encode([2, Enum.map(ss, &decoded_to_term/1)])
  defp encode({:n_of_k, n, ss}), do: CBOR.encode([3, n, Enum.map(ss, &decoded_to_term/1)])
  defp encode({:invalid_before, s}), do: CBOR.encode([4, s])
  defp encode({:invalid_hereafter, s}), do: CBOR.encode([5, s])

  # For nested scripts we need the TERM (not pre-encoded bytes) so the parent encodes as one array.
  defp decoded_to_term({:sig, kh}), do: [0, %CBOR.Tag{tag: :bytes, value: kh}]
  defp decoded_to_term({:all, ss}), do: [1, Enum.map(ss, &decoded_to_term/1)]
  defp decoded_to_term({:any, ss}), do: [2, Enum.map(ss, &decoded_to_term/1)]
  defp decoded_to_term({:n_of_k, n, ss}), do: [3, n, Enum.map(ss, &decoded_to_term/1)]
  defp decoded_to_term({:invalid_before, s}), do: [4, s]
  defp decoded_to_term({:invalid_hereafter, s}), do: [5, s]
end
