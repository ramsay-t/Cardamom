defmodule Cardamom.Ledger.HeaderRegistry do
  @moduledoc """
  Unique Registry mapping a header's identity (era-tagged raw bytes hash) → its live
  `Cardamom.Ledger.HeaderHandler` pid. Mirrors `Cardamom.Ledger.BlockRegistry`. Lets
  `HeaderSupervisor` dedupe (a re-seen header collides on the registered name) and keeps the entry
  only while the handler lives (removed automatically on exit).
  """

  @doc false
  def child_spec(_arg) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end
end
