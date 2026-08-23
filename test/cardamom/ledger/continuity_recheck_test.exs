defmodule Cardamom.Ledger.ContinuityRecheckTest do
  @moduledoc """
  When a floating header becomes CONNECTED in the forest, continuity is re-run (the deferral from
  the header gate). A now-invalid link (wrong block number / non-increasing slot, discoverable only
  once the parent is present) emits a `[:cardamom, :ledger, :divergence]` finding; a good link is
  silent.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.{ChainStore, Ledger.ContinuityRecheck}

  defp store_header(hash, prev, block_no, slot) do
    ChainStore.put_header(%{
      hash: hash, prev_hash: prev, block_no: block_no, slot: slot,
      issuer_vkey: <<0::256>>, vrf_vkey: <<0::256>>, block_body_size: 0,
      block_body_hash: <<0::256>>, protocol_major: 8, protocol_minor: 0, raw: <<0>>
    })
  end

  defp hex(b), do: Base.encode16(b, case: :lower)

  defp capture(fun) do
    id = make_ref()
    me = self()
    :telemetry.attach(id, [:cardamom, :ledger, :divergence],
      fn _e, _m, meta, _ -> if meta[:check] == :header_continuity, do: send(me, {:div, meta}) end, nil)
    try do fun.() after :telemetry.detach(id) end
    receive do {:div, meta} -> meta after 50 -> nil end
  end

  test "a well-linked header rechecks silently (no divergence)" do
    parent = <<1::256>>
    child = <<2::256>>
    store_header(parent, nil, 0, 0)
    store_header(child, parent, 1, 100)

    assert capture(fn -> ContinuityRecheck.recheck(hex(child)) end) == nil
  end

  test "a header linking to a wrong-numbered parent emits a continuity divergence on connect" do
    parent = <<1::256>>
    child = <<2::256>>
    store_header(parent, nil, 0, 0)
    # child claims block_no 5, but parent is 0 → expected 1 → violation
    store_header(child, parent, 5, 100)

    meta = capture(fn -> ContinuityRecheck.recheck(hex(child)) end)
    assert %{check: :header_continuity, header: _} = meta
    assert meta.reason =~ "block_number"
  end

  test "a non-increasing slot is caught on connect" do
    parent = <<1::256>>
    child = <<2::256>>
    store_header(parent, nil, 4, 200)
    store_header(child, parent, 5, 150)

    meta = capture(fn -> ContinuityRecheck.recheck(hex(child)) end)
    assert meta.reason =~ "slot_not_increasing"
  end

  test "an unknown / not-yet-stored header rechecks silently, never raises" do
    assert capture(fn -> ContinuityRecheck.recheck(hex(<<9::256>>)) end) == nil
  end
end
