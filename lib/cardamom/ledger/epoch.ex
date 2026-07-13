defmodule Cardamom.Ledger.Epoch do
  @moduledoc """
  Epoch arithmetic — which epoch a slot belongs to, and whether a new block crosses a boundary.
  The reward/pot engine fires at epoch boundaries, so this is the clock.

  Shelley-era epochs are `epochLength` slots long, starting at slot 0 of the Shelley era. On
  Cardano the Byron era used a different slot regime, but Preview is Shelley-from-genesis (Byron
  is effectively absent), so `epoch(slot) = slot ÷ epochLength` holds for the slots we see. (If we
  ever needed Byron-boundary handling this would gain a Byron-era offset; not needed for Preview.)

  Params come from the network's SHELLEY GENESIS (read, never hardcoded — Preview differs from
  mainnet): Preview `epochLength = 86400`, `activeSlotsCoeff = 0.05` (f), `securityParam` k = 432,
  `maxLovelaceSupply = 45e15`. `params/0` supplies the resolved values (app-env overridable);
  the pure functions take an explicit epoch length so they're testable in isolation.
  """

  @doc """
  Resolved epoch + reward params for this run: %{epoch_length, active_slots_coeff,
  max_lovelace_supply, security_param, a0, nopt, rho, tau}. App-env overridable (tests / other
  networks); defaults are Preview's SHELLEY GENESIS values (protocolParams: a0 0.3, nOpt 150,
  rho 0.003, tau 0.2 — as exact rationals, never floats). TODO (with Tier-a enacted-param
  tracking): a protocol-parameter-update gov action can change a0/nopt/rho/tau on-chain; until we
  track enactment these stay genesis-valued and the conformance oracles are the drift alarm.
  """
  def params do
    Application.get_env(:cardamom, :epoch_params, %{
      epoch_length: 86_400,
      active_slots_coeff: {1, 20},
      max_lovelace_supply: 45_000_000_000_000_000,
      security_param: 432,
      a0: {3, 10},
      nopt: 150,
      rho: {3, 1000},
      tau: {1, 5}
    })
  end

  @doc "The epoch number a slot falls in, given the epoch length in slots."
  @spec of(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def of(slot, epoch_length) when is_integer(slot) and slot >= 0 and epoch_length > 0,
    do: Kernel.div(slot, epoch_length)

  @doc "The epoch a slot falls in, using the resolved run params."
  def of(slot), do: of(slot, params().epoch_length)

  @doc "First slot of an epoch (its lower boundary)."
  @spec first_slot(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def first_slot(epoch, epoch_length) when epoch >= 0 and epoch_length > 0, do: epoch * epoch_length

  @doc """
  Does moving from `prev_slot` to `slot` CROSS one or more epoch boundaries? Returns the list of
  epoch numbers newly ENTERED (usually 0 or 1; more only if slots were skipped across a boundary,
  which shouldn't happen block-to-block but we handle it). `prev_slot` nil = first block seen
  (enter its epoch). Empty list = same epoch, no boundary.
  """
  @spec boundaries_crossed(non_neg_integer() | nil, non_neg_integer(), pos_integer()) :: [non_neg_integer()]
  def boundaries_crossed(nil, slot, epoch_length), do: [of(slot, epoch_length)]

  def boundaries_crossed(prev_slot, slot, epoch_length) do
    prev_e = of(prev_slot, epoch_length)
    cur_e = of(slot, epoch_length)
    if cur_e > prev_e, do: Enum.to_list((prev_e + 1)..cur_e), else: []
  end
end
