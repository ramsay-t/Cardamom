defmodule Cardamom.CryptoTest do
  use ExUnit.Case, async: true

  alias Cardamom.Crypto

  # Pin blake2b-256 to its STANDARD test vector, so a dependency change can never
  # silently alter the hash. Correct-or-nothing for crypto primitives.
  test "blake2b_256 matches the canonical test vector for \"abc\"" do
    assert Base.encode16(Crypto.blake2b_256("abc"), case: :lower) ==
             "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"
  end

  test "blake2b_256 of empty input matches the canonical vector" do
    assert Base.encode16(Crypto.blake2b_256(""), case: :lower) ==
             "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
  end

  test "produces 32 bytes (256 bits)" do
    assert byte_size(Crypto.blake2b_256("anything")) == 32
  end

  test "is deterministic" do
    assert Crypto.blake2b_256("x") == Crypto.blake2b_256("x")
  end
end
