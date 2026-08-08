defmodule Cardamom.Ledger.Conway.Witness do
  @moduledoc """
  Decode `transaction_witness_set` (conway.cddl) into inert structural terms — the surface the
  phase-1 witness rules stand on: vkey-signature verification (`witsVKeyNeeded`), native-script
  evaluation, and (later) the script-integrity hash over plutus data/redeemers.

  HARVARD BOUNDARY: everything here is DATA, never anything callable. Native scripts decode to a
  tagged tree we EVALUATE structurally; plutus scripts/data/redeemers are kept RAW (phase-2 is
  opaque to an observer — we trust the recorded is_valid flag). No atom is derived from wire bytes.

      transaction_witness_set =
        { ? 0 : [* vkeywitness]        vkeywitness = [vkey(32), signature(64)]
        , ? 1 : [* native_script]
        , ? 2 : [* bootstrap_witness]  [vkey, sig, chain_code, attributes]
        , ? 3 : [* plutus_v1_script]   (raw)
        , ? 4 : [* plutus_data]        (raw)
        , ? 5 : redeemers              (raw)
        , ? 6 : [* plutus_v2_script]   (raw)
        , ? 7 : [* plutus_v3_script] } (raw)

      native_script = [0,keyhash] | [1,[s]] | [2,[s]] | [3,n,[s]] | [4,slot] | [5,slot]
        → {:sig,h} | {:all,[…]} | {:any,[…]} | {:n_of_k,n,[…]} | {:invalid_before,s}
          | {:invalid_hereafter,s}   (recursive; unknown shape → {:unknown, raw})

  Conway wraps the per-key lists in CBOR set tag #6.258 — both bare arrays and set-tagged are
  accepted. Malformed entries are DROPPED (never raise): a decoder over adversarial bytes must
  degrade, and a missing/odd witness surfaces later as a coverage/verification failure, loudly.
  """

  @type native ::
          {:sig, binary()}
          | {:all, [native()]}
          | {:any, [native()]}
          | {:n_of_k, integer(), [native()]}
          | {:invalid_before, integer()}
          | {:invalid_hereafter, integer()}
          | {:unknown, term()}

  @type t :: %{
          vkey: [{binary(), binary()}],
          native: [native()],
          bootstrap: [map()],
          plutus_v1: list(),
          plutus_data: list(),
          redeemers: term(),
          plutus_v2: list(),
          plutus_v3: list()
        }

  @empty %{
    vkey: [],
    native: [],
    bootstrap: [],
    plutus_v1: [],
    plutus_data: [],
    redeemers: nil,
    plutus_v2: [],
    plutus_v3: []
  }

  @doc "Decode one `transaction_witness_set` map into the inert term. `nil`/non-map → all-empty."
  @spec decode(map() | nil) :: t()
  def decode(nil), do: @empty
  def decode(m) when not is_map(m), do: @empty

  def decode(m) do
    %{
      @empty
      | vkey: decode_vkeys(items(Map.get(m, 0))),
        native: Enum.map(items(Map.get(m, 1)), &native/1),
        bootstrap: decode_bootstraps(items(Map.get(m, 2))),
        plutus_v1: items(Map.get(m, 3)),
        plutus_data: items(Map.get(m, 4)),
        redeemers: Map.get(m, 5),
        plutus_v2: items(Map.get(m, 6)),
        plutus_v3: items(Map.get(m, 7))
    }
  end

  @doc """
  Decode ALL witness sets of a raw block (the segwit segment, positionally aligned with the tx
  bodies). `{:ok, [t()]}` | `{:error, reason}`. Reuses the block segmenter so it sees the exact
  received bytes.
  """
  @spec decode_block_witnesses(binary()) :: {:ok, [t()]} | {:error, term()}
  def decode_block_witnesses(raw) when is_binary(raw) do
    with {:ok, wits_list} <- Cardamom.Ledger.Conway.Block.witness_sets(raw) do
      {:ok, Enum.map(wits_list, &decode/1)}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  # ---- vkey witnesses ----

  defp decode_vkeys(list) do
    Enum.flat_map(list, fn
      [vk, sig] ->
        case {unbytes(vk), unbytes(sig)} do
          {v, s} when byte_size(v) == 32 and byte_size(s) == 64 -> [{v, s}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp decode_bootstraps(list) do
    Enum.flat_map(list, fn
      [vk, sig, cc, _attrs] -> [%{vkey: unbytes(vk), signature: unbytes(sig), chain_code: unbytes(cc)}]
      _ -> []
    end)
  end

  # ---- native scripts (recursive) ----

  defp native([0, keyhash]), do: {:sig, unbytes(keyhash)}
  defp native([1, scripts]) when is_list(scripts), do: {:all, Enum.map(scripts, &native/1)}
  defp native([2, scripts]) when is_list(scripts), do: {:any, Enum.map(scripts, &native/1)}

  defp native([3, n, scripts]) when is_integer(n) and is_list(scripts),
    do: {:n_of_k, n, Enum.map(scripts, &native/1)}

  defp native([4, slot]) when is_integer(slot), do: {:invalid_before, slot}
  defp native([5, slot]) when is_integer(slot), do: {:invalid_hereafter, slot}
  defp native(other), do: {:unknown, other}

  # ---- helpers ----

  # A witness list is a bare array or a #6.258 set; normalise to a plain list.
  defp items(nil), do: []
  defp items(%CBOR.Tag{tag: 258, value: list}) when is_list(list), do: list
  defp items(list) when is_list(list), do: list
  defp items(_), do: []

  defp unbytes(%CBOR.Tag{tag: :bytes, value: b}), do: b
  defp unbytes(b) when is_binary(b), do: b
  defp unbytes(other), do: other
end
