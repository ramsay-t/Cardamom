defmodule Cardamom.Ledger.WitnessCheck do
  @moduledoc """
  Phase-1 WITNESS rules (Conway UTXOW) — the first checks to consume the decoded witness set
  (`Cardamom.Ledger.Conway.Witness`). Two verdict results per tx:

    * `:vkey_signatures` — every vkey witness `{vkey, sig}` must be a valid Ed25519 signature
      over the TXID (the tx body hash; Ed25519 hashes internally, so we verify over the 32-byte
      txid directly). A single bad signature is a violation.
    * `:witness_coverage` (`witsVKeyNeeded`) — every KEY-hash the tx requires a signature from
      must have a matching vkey witness present. The needed set:
        payment key-hashes of spent inputs  ∪  payment key-hashes of collateral inputs
        ∪  reward-account key-hashes of withdrawals  ∪  required_signers (body key 14).
      SCRIPT credentials are excluded — native/plutus witnesses satisfy those, not vkeys.

  Verify-only, pure, context-light: `read` resolves a spent input `(txid, ix)` to its stored TXO
  (for the address' payment credential). An input we can't resolve yet means we can't compute its
  contribution to the needed set → coverage SKIPS (no false reject), consistent with the
  conservation oracle's unresolved-input handling. Signatures are still checked regardless.

  Results are `{rule, :pass | {:skip,_} | {:violation, detail}, opts}` with the tx's `:txid`
  stamped — same shape the rest of the verdict pipeline uses.
  """

  alias Cardamom.Crypto
  alias Cardamom.Ledger.Address

  @doc "Run the witness rules for one decoded tx (must carry `:witnesses`, `:txid`, `:inputs`)."
  def check(tx, read) when is_map(tx) and is_function(read, 2) do
    txid = Map.get(tx, :txid)
    w = Map.get(tx, :witnesses, %{})
    vkeys = Map.get(w, :vkey, [])

    sig_result = check_signatures(txid, vkeys)
    cov_result = check_coverage(tx, vkeys, read)

    {stamp([sig_result, cov_result], txid), :ok}
  end

  # ---- signature validity ----

  defp check_signatures(txid, vkeys) when is_binary(txid) do
    bad =
      Enum.reject(vkeys, fn {vk, sig} -> Crypto.ed25519_verify(txid, sig, vk) end)

    case bad do
      [] -> {:vkey_signatures, :pass, []}
      _ -> {:vkey_signatures, {:violation, %{invalid: length(bad)}}, []}
    end
  end

  defp check_signatures(_txid, _vkeys), do: {:vkey_signatures, {:skip, :no_txid}, []}

  # ---- coverage (witsVKeyNeeded) ----

  defp check_coverage(tx, vkeys, read) do
    supplied = MapSet.new(vkeys, fn {vk, _sig} -> Crypto.blake2b_224(vk) end)

    case needed_key_hashes(tx, read) do
      {:ok, needed} ->
        missing = MapSet.difference(needed, supplied) |> MapSet.to_list()

        if missing == [],
          do: {:witness_coverage, :pass, []},
          else: {:witness_coverage, {:violation, %{missing: Enum.map(missing, &hex/1)}}, []}

      {:unresolved, ref} ->
        {:witness_coverage, {:skip, {:unresolved_input, ref}}, []}
    end
  end

  # The set of KEY-hashes that must sign, or {:unresolved, ref} if an input's address is unknown.
  defp needed_key_hashes(tx, read) do
    inputs = Map.get(tx, :inputs, []) ++ Map.get(tx, :collateral_inputs, [])

    with {:ok, input_khs} <- input_key_hashes(inputs, read) do
      wdrl_khs = withdrawal_key_hashes(Map.get(tx, :withdrawals, []))
      req_khs = required_signer_hashes(Map.get(tx, :required_signers))
      {:ok, input_khs |> MapSet.union(wdrl_khs) |> MapSet.union(req_khs)}
    end
  end

  # Resolve each input to its TXO's address payment credential; :key hashes count, :script don't.
  defp input_key_hashes(inputs, read) do
    Enum.reduce_while(inputs, {:ok, MapSet.new()}, fn {txid, ix}, {:ok, acc} ->
      case read.(txid, ix) do
        %{address: addr} when is_binary(addr) ->
          case Address.payment_credential(addr) do
            {:key, kh} -> {:cont, {:ok, MapSet.put(acc, kh)}}
            _ -> {:cont, {:ok, acc}}
          end

        _ ->
          {:halt, {:unresolved, {hex(txid), ix}}}
      end
    end)
  end

  defp withdrawal_key_hashes(withdrawals) do
    for {addr, _coin} <- withdrawals,
        {:key, kh} <- [Address.stake_credential(addr)],
        into: MapSet.new(),
        do: kh
  end

  # required_signers (body key 14) is a set of raw 28-byte key-hashes.
  defp required_signer_hashes(nil), do: MapSet.new()
  defp required_signer_hashes(%CBOR.Tag{tag: 258, value: list}), do: required_signer_hashes(list)

  defp required_signer_hashes(list) when is_list(list) do
    for kh <- list, into: MapSet.new(), do: unbytes(kh)
  end

  defp required_signer_hashes(_), do: MapSet.new()

  defp stamp(results, txid),
    do: Enum.map(results, fn {r, o, opts} -> {r, o, Keyword.put(opts, :txid, txid)} end)

  defp unbytes(%CBOR.Tag{tag: :bytes, value: b}), do: b
  defp unbytes(b) when is_binary(b), do: b
  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)
  defp hex(other), do: inspect(other)
end
