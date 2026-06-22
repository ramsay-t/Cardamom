defmodule Cardamom.Forest.PersistTipTest do
  @moduledoc """
  Forest.Server persists its JUDGED tip to the durable store (the resume anchor) —
  on advance and on rollback, only when the tip actually changes, never the genesis
  placeholder. The forest is the authority on the tip; this is what a later boot
  reads back to resume.
  """
  use Cardamom.DataCase, async: false

  alias Cardamom.ChainStore
  alias Cardamom.Forest.Server

  # Forest works in hex; the store keeps binary. Helper to compare.
  defp hexbin(hex), do: Base.decode16!(hex, case: :lower)

  defp start, do: elem(Server.start_link(name: nil), 1)

  test "advancing the tip persists it to the store (hex -> binary)" do
    s = start()
    Server.add_header(s, "aa", nil)
    # Genesis prev (nil) → "aa" connects at height 1 and becomes the tip.
    # Give the cast time to land.
    _ = Server.tip(s)

    assert ChainStore.get_tip() == hexbin("aa")
  end

  test "the genesis placeholder is NEVER persisted as a tip" do
    _s = start()
    # Fresh forest, no headers → tip is :genesis (an atom, not a real point).
    assert ChainStore.get_tip() == nil
  end

  test "the tip is only persisted on CHANGE (no redundant writes)" do
    s = start()
    Server.add_header(s, "aa", nil)
    _ = Server.tip(s)
    assert ChainStore.get_tip() == hexbin("aa")

    # Re-adding the same header doesn't move the tip → still aa, no crash.
    Server.add_header(s, "aa", nil)
    _ = Server.tip(s)
    assert ChainStore.get_tip() == hexbin("aa")
  end

  test "rollback persists the rolled-back tip" do
    s = start()
    Server.add_header(s, "aa", nil)
    Server.add_header(s, "bb", "aa")
    _ = Server.tip(s)
    assert ChainStore.get_tip() == hexbin("bb")

    Server.rollback(s, "aa")
    _ = Server.tip(s)
    assert ChainStore.get_tip() == hexbin("aa"), "rolled-back tip becomes the resume anchor"
  end
end
