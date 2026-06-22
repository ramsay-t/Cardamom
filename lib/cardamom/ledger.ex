defmodule Cardamom.Ledger do
  @moduledoc """
  The ledger layer behaviour — what a header/block/point *means*. The network
  layer (chain-sync, Connection) is GENERIC over the header (the Ouroboros
  protocol parameterises header/point/tip), so we keep that genericity: the
  network layer moves opaque raw header bytes; this behaviour interprets them.
  Era-specific decode (Conway header fields, ledger state transition, datums) is
  an implementation of THIS behaviour, never hardcoded into the network layer.

  Injected as a `{module, handle}` pair (same seam as `Channel`/`PeerStore`), so
  the network layer talks to `Cardamom.Ledger.Stub` now and a real era ledger
  later, with no change to `Connection`.

  A `point` is `%{slot: slot | :unknown, hash: <32 bytes>, hash_hex: String.t()}`
  — the header's position/identity, which is what the network layer needs to track
  its sync cursor (the hash is era-independent; the slot needs real decode).
  """

  @type handle :: {module(), term()}
  @type point :: %{slot: non_neg_integer() | :unknown, hash: binary(), hash_hex: String.t()}

  @doc "Interpret opaque raw header bytes into a point (position/identity)."
  @callback header_point(term(), raw_header :: binary()) :: {:ok, point()} | {:error, term()}

  @spec header_point(handle(), binary()) :: {:ok, point()} | {:error, term()}
  def header_point({mod, h}, raw_header), do: mod.header_point(h, raw_header)
end
