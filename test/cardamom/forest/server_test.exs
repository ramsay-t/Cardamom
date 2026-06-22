defmodule Cardamom.Forest.ServerTest do
  use ExUnit.Case, async: true

  alias Cardamom.Forest.Server

  defp start(root \\ "root") do
    {:ok, pid} = Server.start_link(root: root, name: nil)
    pid
  end

  test "feeding headers advances the tip" do
    s = start()
    Server.add_header(s, "a", "root")
    Server.add_header(s, "b", "a")
    assert Server.tip(s) == "b"
  end

  test "out-of-order headers coalesce (gaps resolve)" do
    s = start()
    Server.add_header(s, "b", "a")
    assert Server.tip(s) == "root", "b is orphaned until a arrives"
    Server.add_header(s, "a", "root")
    assert Server.tip(s) == "b", "a arriving links b to root"
  end

  test "rollback moves the tip" do
    s = start()
    Server.add_header(s, "a", "root")
    Server.add_header(s, "b", "a")
    Server.rollback(s, "a")
    assert Server.tip(s) == "a"
  end

  test "status reports tip and a height" do
    s = start()
    Server.add_header(s, "a", "root")
    st = Server.status(s)
    assert st.tip == "a"
    assert st.tip_height == 1
  end

  test "adding a header emits a telemetry event" do
    test_pid = self()

    :telemetry.attach(
      "forest-add-#{System.unique_integer([:positive])}",
      [:cardamom, :forest, :header],
      fn _e, _m, meta, _ -> send(test_pid, {:forest, meta}) end,
      nil
    )

    s = start()
    Server.add_header(s, "a", "root")
    assert_receive {:forest, %{hash: "a", tip: "a"}}, 500
  end
end
