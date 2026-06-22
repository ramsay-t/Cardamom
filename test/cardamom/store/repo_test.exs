defmodule Cardamom.Store.RepoTest do
  @moduledoc """
  db_path/1 is a SAFETY function: it derives the per-network DB filename so stores
  can't cross-contaminate, and REFUSES mainnet outright (we never store mainnet).
  These are the guards Ramsay was emphatic about — test them hard.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Store.Repo

  @mainnet 764_824_073

  test "derives a magic-tagged path for valid networks" do
    assert Repo.db_path(2) == Path.join("data", "forest-2.db")
    assert Repo.db_path(1) == Path.join("data", "forest-1.db")
    assert Repo.db_path(42) == Path.join("data", "forest-42.db")
  end

  test "different magics yield DIFFERENT files (no cross-contamination)" do
    refute Repo.db_path(1) == Repo.db_path(2)
    refute Repo.db_path(2) == Repo.db_path(1_097_911_063)
  end

  test "REFUSES mainnet outright (we never store mainnet)" do
    assert_raise ArgumentError, ~r/mainnet/, fn -> Repo.db_path(@mainnet) end
  end

  test "rejects a negative magic (not a real network)" do
    assert_raise FunctionClauseError, fn -> Repo.db_path(-1) end
  end

  test "rejects a non-integer magic" do
    assert_raise FunctionClauseError, fn -> Repo.db_path("2") end
    assert_raise FunctionClauseError, fn -> Repo.db_path(nil) end
  end

  test "the path is named forest-<magic>.db" do
    path = Repo.db_path(2)
    assert Path.basename(path) == "forest-2.db"
  end

  test "real_magics lists the known networks" do
    m = Repo.real_magics()
    assert m.mainnet == @mainnet
    assert m.preprod == 1
    assert m.preview == 2
    assert m.legacy_testnet == 1_097_911_063
  end

  test "safe_test_magic? rejects every known real magic" do
    for {_net, magic} <- Repo.real_magics() do
      refute Repo.safe_test_magic?(magic), "magic #{magic} is real — must NOT be a safe test magic"
    end
  end

  test "safe_test_magic? accepts a value outside the real set" do
    assert Repo.safe_test_magic?(900_000_001)
    assert Repo.safe_test_magic?(42)
  end

  test "safe_test_magic? rejects non-integers" do
    refute Repo.safe_test_magic?("2")
    refute Repo.safe_test_magic?(nil)
  end

  test "the actual TEST-RUN DB uses a safe (non-real) magic and forest-<magic>.db shape" do
    db = Application.get_env(:cardamom, Repo)[:database]
    assert is_binary(db)
    # forest-<magic>.db shape
    assert ["forest", magic_str] = Path.basename(db, ".db") |> String.split("-")
    magic = String.to_integer(magic_str)
    # ...and that magic is provably NOT a real network.
    assert Repo.safe_test_magic?(magic),
           "test DB magic #{magic} must never collide with a real network"
  end
end
