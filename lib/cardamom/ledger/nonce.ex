defmodule Cardamom.Ledger.Nonce do
  @moduledoc """
  Epoch-nonce (η) evolution — the chain's self-generated randomness beacon that seeds
  Praos VRF leader election. Pure; the pieces that feed it (per-block VRF outputs, the
  epoch clock) come from the header stream.

  SOURCES (pinned 2026-08-04, all code/spec-only — flag class):
    * `⭒` combine + `mkNonceFromOutputVRF` — cardano-ledger BaseTypes:
      `Nonce a ⭒ Nonce b = blake2b256(bytes a ‖ bytes b)`, NeutralNonce is the identity;
      a VRF output becomes a nonce by `blake2b256(getOutputVRFBytes)` — the RAW 64-byte
      output (NOT the "N"-domain-separated value used elsewhere).
    * UPDN transition — consensus `Spec/UpdateNonce.lagda`: per block the EVOLVING nonce
      absorbs the block nonce (`ηv ← ηv ⭒ η`); the CANDIDATE tracks the evolving nonce
      until the slot enters the randomness-stabilisation window near the epoch end, then
      FREEZES (anti-grinding — a late leader can no longer steer next epoch's lottery).
    * epoch tick — consensus Praos.hs: `η_epoch ← candidate ⭒ η_lastEpochLastBlock`,
      the lagged component being a nonce derived from the previous epoch's final block.
    * window — ledger StabilityWindow: `randomnessStabilisationWindow = ⌈4k/f⌉`
      (modern Praos; pre-Praos Shelley used ⌈3k/f⌉ — not relevant to our Babbage+ data).

  A nonce value is a 32-byte binary, or the atom `:neutral` (NeutralNonce). State is
  `%{evolving, candidate, epoch}` — the three registers Praos threads through the chain.
  """

  alias Cardamom.Crypto

  @type nonce :: <<_::256>> | :neutral
  @type t :: %__MODULE__{evolving: nonce(), candidate: nonce(), epoch: nonce()}

  defstruct evolving: :neutral, candidate: :neutral, epoch: :neutral

  @doc "Initial state at an epoch nonce (e.g. genesis η, or an epoch we start folding from)."
  def initial(epoch_nonce \\ :neutral) do
    %__MODULE__{evolving: epoch_nonce, candidate: epoch_nonce, epoch: epoch_nonce}
  end

  @doc "`a ⭒ b` — blake2b256(a ‖ b); `:neutral` is the identity element."
  def combine(:neutral, b), do: b
  def combine(a, :neutral), do: a

  def combine(a, b) when is_binary(a) and is_binary(b) do
    Crypto.blake2b_256(a <> b)
  end

  @doc "Nonce from a block's raw 64-byte VRF output — blake2b256 of those bytes."
  def from_vrf_output(vrf_output) when is_binary(vrf_output) do
    Crypto.blake2b_256(vrf_output)
  end

  @doc "randomnessStabilisationWindow = ⌈4k/f⌉ slots, from k (securityParam) and f = {num, den}."
  def stabilisation_window(%{security_param: k, active_slots_coeff: {fn_, fd}}) do
    # ceil(4k / (fn/fd)) = ceil(4k·fd / fn)
    ceil_div(4 * k * fd, fn_)
  end

  @doc """
  UPDN — absorb one block's VRF output at `slot` into the evolving nonce, and into the
  candidate too UNLESS the slot has entered the stabilisation window (then the candidate
  is frozen for the rest of the epoch).
  """
  def update(%__MODULE__{} = st, slot, vrf_output, params) do
    eta = from_vrf_output(vrf_output)
    evolving = combine(st.evolving, eta)
    candidate = if in_stabilisation_window?(slot, params), do: st.candidate, else: evolving
    %{st | evolving: evolving, candidate: candidate}
  end

  @doc """
  Epoch boundary tick: the new epoch nonce is the (frozen) candidate combined with the
  lagged last-block nonce of the epoch just ended; the evolving/candidate registers reset
  to it for the new epoch.
  """
  def tick_epoch(%__MODULE__{} = st, last_epoch_last_block_nonce) do
    epoch = combine(st.candidate, last_epoch_last_block_nonce)
    %__MODULE__{evolving: epoch, candidate: epoch, epoch: epoch}
  end

  # The candidate freezes once slot + window ≥ the first slot of the next epoch.
  defp in_stabilisation_window?(slot, %{epoch_length: len} = params) do
    epoch = div(slot, len)
    next_epoch_first_slot = (epoch + 1) * len
    slot + stabilisation_window(params) >= next_epoch_first_slot
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
