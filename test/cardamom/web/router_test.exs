defmodule Cardamom.Web.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Cardamom.Web.Router

  @opts Router.init([])

  defp call(method, path) do
    conn(method, path) |> Router.call(@opts)
  end

  test "GET / serves the HTML dashboard" do
    conn = call(:get, "/")
    assert conn.status == 200
    assert conn.resp_body =~ "Cardamom"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
  end

  test "GET /stats.json returns JSON with the expected keys" do
    conn = call(:get, "/stats.json")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Map.has_key?(body, "uptime_seconds")
    assert Map.has_key?(body, "recent")
  end

  test "GET /peers.json returns the peer list" do
    conn = call(:get, "/peers.json")
    assert conn.status == 200
    assert is_list(Jason.decode!(conn.resp_body)["peers"])
  end

  test "GET /chaindata.json returns the backfill summary + recent txs" do
    conn = call(:get, "/chaindata.json")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    # The body-backfill progress fields the UI panel reads.
    for k <- ~w(headers bodies gap pending txos unspent spent) do
      assert is_integer(body[k]), "#{k} should be an integer count"
    end
    assert is_list(body["recent_txs"])
  end

  test "GET /system.json returns the VM summary" do
    conn = call(:get, "/system.json")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["process_count"] > 0
  end

  test "GET /processes.json returns a process list" do
    conn = call(:get, "/processes.json")
    assert conn.status == 200
    assert is_list(Jason.decode!(conn.resp_body)["processes"])
  end

  test "GET /tree.json returns the supervision tree" do
    conn = call(:get, "/tree.json")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["type"] == "supervisor"
  end

  test "unknown path returns 404" do
    conn = call(:get, "/nope")
    assert conn.status == 404
  end
end
