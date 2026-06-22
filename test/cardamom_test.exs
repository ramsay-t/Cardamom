defmodule CardamomTest do
  use ExUnit.Case

  test "the control API delegates exist" do
    # The top-level module is the control surface (thin delegates to Control).
    Code.ensure_loaded!(Cardamom)
    assert function_exported?(Cardamom, :status, 0)
    assert function_exported?(Cardamom, :disconnect_all, 0)
    assert function_exported?(Cardamom, :shutdown, 0)
  end
end
