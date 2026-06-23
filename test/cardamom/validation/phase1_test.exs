defmodule Cardamom.Validation.Phase1Test do
  @moduledoc """
  Phase-1 (structural/ledger) validation — the subset we can do WITHOUT protocol params,
  witness/signature verification, or slot tracking. Each check cites a precondition of the
  Conway UTxO rule (Agda Utxo.lagda.md ~544-546; see reference_agda_utxo_separation):

    * txIns ≢ ∅                    — a tx must spend something
    * txIns ∩ refInputs ≡ ∅        — can't spend AND reference the same UTxO
    * txIns ∪ refInputs ⊆ dom utxo — inputs/refs must EXIST (and be unspent)
    * coin mint ≡ 0                — ADA cannot be minted
    * (no double-spend)            — an input already spent in our confirmed set

  Three-valued result, honest about our incomplete UTxO view:
    :ok                       — passes every check we CAN make
    {:rejected, reason}       — DEFINITELY bad (malformed / double-spend / mint ADA / etc.)
    {:unverifiable, missing}  — we can't see an input's source yet (unsynced) — NOT the
                                peer's fault, must not penalise them.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.Conway.Tx

  defp b(x), do: %CBOR.Tag{tag: :bytes, value: x}

  defp tx(body_map) do
    {:ok, t} = Tx.decode_tx(CBOR.encode(body_map))
    t
  end

  # Seed a confirmed, unspent UTxO so inputs can resolve.
  defp seed_utxo(txid, ix, value \\ 1_000_000) do
    {:ok, _} = Cardamom.Store.Repo.insert(%Cardamom.Store.Txo{txid: txid, ix: ix, value: value})
  end

  test "a tx spending an existing unspent input passes" do
    seed_utxo(<<1::256>>, 0)
    t = tx(%{0 => [[b(<<1::256>>), 0]], 1 => [[b(<<0xAA>>), 5]]})
    assert :ok = ChainStore.validate_tx_phase1(t)
  end

  test "empty inputs are rejected (txIns ≢ ∅, Agda ~544)" do
    t = tx(%{0 => [], 1 => [[b(<<0xAA>>), 5]]})
    assert {:rejected, :no_inputs} = ChainStore.validate_tx_phase1(t)
  end

  test "spending AND referencing the same UTxO is rejected (txIns ∩ refInputs ≡ ∅, ~545)" do
    seed_utxo(<<1::256>>, 0)
    t = tx(%{0 => [[b(<<1::256>>), 0]], 1 => [], 18 => [[b(<<1::256>>), 0]]})
    assert {:rejected, :spend_reference_overlap} = ChainStore.validate_tx_phase1(t)
  end

  test "a double-spend (input exists but is already spent) is rejected" do
    # Seed it spent.
    {:ok, _} =
      Cardamom.Store.Repo.insert(%Cardamom.Store.Txo{
        txid: <<2::256>>, ix: 0, value: 5, spent_by: <<9::256>>, spent_how: "tx_input"
      })

    t = tx(%{0 => [[b(<<2::256>>), 0]], 1 => [[b(<<0xAA>>), 1]]})
    assert {:rejected, {:double_spend, [{<<2::256>>, 0}]}} = ChainStore.validate_tx_phase1(t)
  end

  test "minting ADA (coin in the mint field) is rejected" do
    # mint (key 9) = multiasset; a bare positive coin / an ADA entry is illegal. We model
    # the simplest illegal case: a non-empty ADA mint. (policy 0x00... = the ada marker
    # isn't how mint works, so we just assert any ADA-coin mint is caught.)
    t = tx(%{0 => [[b(<<1::256>>), 0]], 1 => [], 9 => 100})
    assert {:rejected, :mint_ada} = ChainStore.validate_tx_phase1(t)
  end

  test "minting a TOKEN (multiasset map, not ADA) is allowed — ADA is unrepresentable there" do
    seed_utxo(<<1::256>>, 0)
    # mint (key 9) = multiasset: policy_id -> (asset_name -> amount). ADA has no policy id,
    # so a multiasset map CANNOT mint ADA — minting a token must pass phase-1 (mints_ada?
    # is false for a map). This is the MC/DC partner to the mint_ada rejection case.
    mint = %{b(<<0xAB::256>>) => %{b("MyToken") => 1000}}
    t = tx(%{0 => [[b(<<1::256>>), 0]], 1 => [[b(<<0xAA>>), 5]], 9 => mint})
    assert :ok = ChainStore.validate_tx_phase1(t)
  end

  test "an input we have NOT seen yet → unverifiable (not rejected; don't blame the peer)" do
    t = tx(%{0 => [[b(<<7::256>>), 0]], 1 => [[b(<<0xAA>>), 1]]})
    assert {:unverifiable, missing} = ChainStore.validate_tx_phase1(t)
    assert {<<7::256>>, 0} in missing
  end

  test "a reference input that doesn't exist is also unverifiable (refInputs ⊆ dom utxo)" do
    seed_utxo(<<1::256>>, 0)
    t = tx(%{0 => [[b(<<1::256>>), 0]], 1 => [], 18 => [[b(<<8::256>>), 0]]})
    assert {:unverifiable, missing} = ChainStore.validate_tx_phase1(t)
    assert {<<8::256>>, 0} in missing
  end
end
