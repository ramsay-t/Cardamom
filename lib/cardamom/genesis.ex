defmodule Cardamom.Genesis do
  @moduledoc """
  Seeds the INITIAL UTXO set from a network's genesis files, BEFORE block ingestion.

  ## Why this exists

  Chain blocks spend genesis UTXOs — the initial funds that live in the GENESIS LEDGER
  STATE, not in any block body. No block PRODUCES them, so without seeding, a tx that
  spends one finds no target output and its block never reaches `txo_processed`. E.g.
  live Preview block 3 spends input
  `4843cf2e582b2f9ce37600e5ab4cc678991f988f8780fed05407f9537f7712bd:0`, which is the
  Byron genesis UTXO for Preview's single non-zero `nonAvvmBalances` entry (30B ADA).
  Seeding genesis up front makes that spend resolve like any other.

  ## Network-agnostic

  Nothing here is Preview-specific: the genesis file PATHS come from config
  (`%{shelley: path | nil, byron: path | nil}`), and the derivations are the protocol's,
  so this works for any Cardano network — including a brand-new one we launch.

  ## Derivations (from cardano-ledger source)

    * **Shelley** — `Cardano.Ledger.Shelley.Genesis.initialFundsPseudoTxIn`
      (Shelley/Genesis.hs:660). For each `(addr, coin)` in `sgInitialFunds`, the UTXO is
      at `TxIn = (pseudoTxId, 0)` where `pseudoTxId = blake2b_256(serialiseAddr(addr))`.
      In shelley-genesis JSON the `initialFunds` KEY is the hex-encoded `serialiseAddr`
      bytes, so `serialiseAddr(addr)` is just the hex-decoded key — hash THOSE.

    * **Byron** — `Cardano.Chain.UTxO.UTxO.fromTxOut` (byron UTxO.hs:130). For each
      `(addr, coin)` the UTXO is at `TxIn = (serializeCborHash(address), 0)` where
      `serializeCborHash = blake2b_256(CBOR_encode(address))`. In byron-genesis JSON the
      `nonAvvmBalances` KEY is the BASE58 form of the Byron address, and a Byron base58
      address IS the base58 of its CBOR `[#6.24(bytes), crc32]`. So base58-decoding the
      key yields `CBOR_encode(address)` ALREADY — hash THOSE bytes directly.

  `avvmDistr` entries derive their address via `makeRedeemAddress` from the redeem
  verification key — NOT implemented here (Preview has 0 avvm entries). See the module's
  `derive_byron/1`: avvm is skipped and surfaced in the summary if ever non-empty.
  """

  alias Cardamom.{ChainStore, Crypto}
  require Logger

  @doc """
  Load the configured genesis files, derive the initial UTXOs, and seed them into the
  confirmed `txos` table (idempotent UPSERT — safe to re-run on every reboot).

  Opts:
    * `:shelley` — path to shelley-genesis.json (or nil to skip)
    * `:byron`   — path to byron-genesis.json (or nil to skip)

  Either accepts the resolved genesis map directly, e.g.
  `load(shelley: "...", byron: "...")`, or pass through `Cardamom.Config`'s
  `:genesis` map. Missing/nil paths are skipped (a network may have only one era's
  genesis funds). Returns `{:ok, count}` with the number of UTXOs seeded.
  """
  @spec load(keyword() | map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load(opts) when is_list(opts), do: load(Map.new(opts))

  def load(%{} = opts) do
    shelley = Map.get(opts, :shelley)
    byron = Map.get(opts, :byron)

    with {:ok, shelley_utxos} <- from_shelley(shelley),
         {:ok, byron_utxos} <- from_byron(byron) do
      utxos = shelley_utxos ++ byron_utxos
      Enum.each(utxos, fn {txid, ix, addr, value} ->
        {:ok, _} = ChainStore.insert_genesis_utxo(txid, ix, addr, value)
      end)

      seed_pots(shelley, utxos)

      count = length(utxos)
      if count > 0, do: Logger.info("genesis: seeded #{count} initial UTXO(s)")
      {:ok, count}
    end
  end

  # Initial accounting POTS (the reward engine's other genesis state): everything not issued as
  # initial UTxO starts in the RESERVES — reserves₀ = maxLovelaceSupply − Σ initial funds — and
  # the treasury starts empty (Shelley genesis has no treasury field). Set ONCE, only when absent
  # (a synced store already has evolved pots; genesis reseeding must not reset them). Direct sets,
  # not journalled ops: genesis precedes every block, so no rollback can cross it.
  defp seed_pots(shelley_path, utxos) do
    if ChainStore.ledger_read(:pot, :reserves) == nil do
      max_supply = max_lovelace_supply(shelley_path)
      issued = Enum.reduce(utxos, 0, fn {_txid, _ix, _addr, value}, acc -> acc + value end)
      ChainStore.ledger_set(:pot, :reserves, max_supply - issued)
      ChainStore.ledger_set(:pot, :treasury, 0)
      Logger.info("genesis: pots seeded — reserves = #{max_supply} - #{issued} (issued)")
    end

    :ok
  end

  defp max_lovelace_supply(shelley_path) when is_binary(shelley_path) do
    case read_json(shelley_path) do
      {:ok, %{"maxLovelaceSupply" => n} = _json} when is_integer(n) -> n
      _ -> Cardamom.Ledger.Epoch.params().max_lovelace_supply
    end
  end

  defp max_lovelace_supply(_), do: Cardamom.Ledger.Epoch.params().max_lovelace_supply

  # ---- Shelley initialFunds ----

  defp from_shelley(nil), do: {:ok, []}

  defp from_shelley(path) when is_binary(path) do
    with {:ok, json} <- read_json(path) do
      {:ok, derive_shelley(Map.get(json, "initialFunds", %{}))}
    end
  end

  @doc """
  Derive Shelley genesis UTXOs from an `initialFunds` map (`%{hex_addr => coin}`).
  Each entry → `{txid, 0, address_bytes, coin}` where `address_bytes` is the hex-decoded
  key (the `serialiseAddr` form) and `txid = blake2b_256(address_bytes)`
  (Shelley/Genesis.hs:660 `initialFundsPseudoTxIn`).
  """
  @spec derive_shelley(map()) :: [{binary(), 0, binary(), non_neg_integer()}]
  def derive_shelley(initial_funds) when is_map(initial_funds) do
    for {hex_addr, coin} <- initial_funds do
      addr = Base.decode16!(hex_addr, case: :mixed)
      {Crypto.blake2b_256(addr), 0, addr, to_coin(coin)}
    end
  end

  # ---- Byron nonAvvmBalances ----

  defp from_byron(nil), do: {:ok, []}

  defp from_byron(path) when is_binary(path) do
    with {:ok, json} <- read_json(path) do
      avvm = Map.get(json, "avvmDistr", %{})

      if map_size(avvm) > 0 do
        # avvm addresses derive via makeRedeemAddress from the redeem VK — NOT implemented
        # (Preview has 0). Loudly surface it so a network that HAS avvm funds isn't silently
        # under-seeded, rather than guessing a derivation we haven't confirmed.
        Logger.warning(
          "genesis: byron avvmDistr has #{map_size(avvm)} entr(y/ies) — NOT seeded " <>
            "(makeRedeemAddress derivation unimplemented); these initial funds are missing"
        )
      end

      {:ok, derive_byron(Map.get(json, "nonAvvmBalances", %{}))}
    end
  end

  @doc """
  Derive Byron genesis UTXOs from a `nonAvvmBalances` map (`%{base58_addr => coin}`).
  Each entry → `{txid, 0, address_cbor, coin}` where `address_cbor` is the base58-decoded
  key (which IS the CBOR encoding of the Byron address) and
  `txid = blake2b_256(address_cbor)` (byron UTxO.hs:130 `fromTxOut` / `serializeCborHash`).
  """
  @spec derive_byron(map()) :: [{binary(), 0, binary(), non_neg_integer()}]
  def derive_byron(non_avvm_balances) when is_map(non_avvm_balances) do
    for {b58_addr, coin} <- non_avvm_balances do
      addr_cbor = base58_decode!(b58_addr)
      {Crypto.blake2b_256(addr_cbor), 0, addr_cbor, to_coin(coin)}
    end
  end

  # Byron coins are JSON STRINGS ("30000000000000000"); Shelley coins are JSON numbers.
  # Accept either; never String.to_integer on something that isn't a clean integer string.
  defp to_coin(n) when is_integer(n), do: n
  defp to_coin(s) when is_binary(s), do: String.to_integer(s)

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      {:error, reason} -> {:error, {:genesis_read, path, reason}}
    end
  end

  # ---- Base58 (Bitcoin alphabet) ----
  # Byron addresses use the standard Bitcoin base58 alphabet. No base58 dependency is in
  # mix.exs, so we hand-roll the decode (it's the only base58 we need). Big-endian
  # base-58 → integer → bytes, preserving leading-'1' bytes as leading 0x00 (standard).

  @b58_alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @b58_index @b58_alphabet |> Enum.with_index() |> Map.new()

  @doc "Decode a Bitcoin-alphabet base58 string to its bytes. Raises on an invalid character."
  @spec base58_decode!(String.t()) :: binary()
  def base58_decode!(str) when is_binary(str) do
    chars = String.to_charlist(str)

    n =
      Enum.reduce(chars, 0, fn c, acc ->
        case Map.fetch(@b58_index, c) do
          {:ok, v} -> acc * 58 + v
          :error -> raise ArgumentError, "invalid base58 character: #{inspect(<<c>>)}"
        end
      end)

    body = :binary.encode_unsigned(n)
    # Leading '1' characters encode leading zero bytes (one 0x00 each).
    leading_zeros = Enum.take_while(chars, &(&1 == ?1)) |> length()
    String.duplicate(<<0>>, leading_zeros) <> body
  end
end
