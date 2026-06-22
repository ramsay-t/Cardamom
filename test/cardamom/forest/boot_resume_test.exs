defmodule Cardamom.Forest.BootResumeTest do
  @moduledoc """
  Proves the BOOT-SEED half of resume (the path built for the 2-run Preview test):
  a Forest.Server, when it starts, anchors itself at the durable stored tip instead
  of genesis — so after a stop+reboot the node knows where it left off BEFORE any
  network activity. Run locally against the real store (no live network).
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Forest.Server
  alias Cardamom.Ledger.Conway.HeaderBuilder

  test "a fresh Forest.Server seeds its root from the durable stored tip" do
    # Simulate 'run 1' having persisted a header and recorded it as the tip.
    hdr = HeaderBuilder.build(block_number: 40, slot: 4_000)
    {:ok, decoded} = Cardamom.Ledger.Conway.Header.decode(hdr.raw)
    {:ok, _} = ChainStore.put_decoded_header(decoded, hdr.raw)
    :ok = ChainStore.put_tip(decoded.hash)

    # 'run 2': a fresh Forest.Server boots. It must anchor at the stored tip (hex),
    # NOT genesis — so its tip is already our resume point with no network.
    {:ok, srv} = Server.start_link(name: nil)

    tip_hex = Base.encode16(decoded.hash, case: :lower)
    assert Server.tip(srv) == tip_hex, "forest seeded from stored tip, not genesis"
  end

  test "with NO stored tip, a fresh Forest.Server starts at genesis (cold start)" do
    {:ok, srv} = Server.start_link(name: nil)
    assert Server.tip(srv) == :genesis
  end

  test "after seeding, the next header connects onto the resumed tip (tracks forward)" do
    hdr = HeaderBuilder.build(block_number: 40, slot: 4_000)
    {:ok, decoded} = Cardamom.Ledger.Conway.Header.decode(hdr.raw)
    {:ok, _} = ChainStore.put_decoded_header(decoded, hdr.raw)
    :ok = ChainStore.put_tip(decoded.hash)
    tip_hex = Base.encode16(decoded.hash, case: :lower)

    {:ok, srv} = Server.start_link(name: nil)

    # A child of the resumed tip should advance the tip forward (not be orphaned) —
    # proving the forest tracks from the resume anchor.
    Server.add_header(srv, "child-of-tip", tip_hex)
    assert Server.tip(srv) == "child-of-tip"
  end
end
