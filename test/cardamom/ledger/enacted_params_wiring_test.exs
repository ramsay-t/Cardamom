defmodule Cardamom.Ledger.EnactedParamsWiringTest do
  @moduledoc """
  End-to-end: enacting a protocol-param-change (via the `:pparams` ledger domain) is reflected in
  the LIVE params `ChainStore.protocol_params/0` reads — so the phase-1 economic rules assert
  against the values actually in force. Enactment ops are invertible, so a rollback restores the
  prior params (same journal machinery as every ledger effect).
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Ledger.ParamUpdate

  test "an enacted coins_per_utxo_byte becomes visible in live protocol_params" do
    # genesis default: coins_per_utxo_byte absent (min-ADA rule skips)
    assert ChainStore.protocol_params().coins_per_utxo_byte == nil

    # enact it — the exact op ParamUpdate.enact_ops would emit for a param-change gov action
    ops = ParamUpdate.enact_ops(%{coins_per_utxo_byte: 4310}, &ChainStore.ledger_read/2)
    assert ops == [{:set, :pparams, :coins_per_utxo_byte, nil, 4310}]
    ChainStore.ledger_apply_block(<<1::256>>, 1, ops)

    live = ChainStore.protocol_params()
    assert live.coins_per_utxo_byte == 4310, "enacted value now in force"
    assert live.min_fee_a == 44, "unchanged params keep genesis defaults"
  end

  test "an enacted min_fee_a override is reflected, and rolls back invertibly" do
    ChainStore.ledger_apply_block(<<2::256>>, 5, [{:set, :pparams, :min_fee_a, 44, 50}])
    assert ChainStore.protocol_params().min_fee_a == 50

    # roll the ledger back below the enactment slot → prior value restored
    ChainStore.ledger_rollback(4)
    assert ChainStore.protocol_params().min_fee_a == 44
  end
end
