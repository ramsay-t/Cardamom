defmodule Cardamom.Mux.ReassemblerTest do
  @moduledoc """
  The generic message-reassembly algorithm shared by every mini-protocol client.

  A mini-protocol message can be split across mux SDU boundaries, OR several whole
  messages can be packed into one SDU. The carry-over algorithm is identical for all
  protocols (concat, decode every WHOLE message, hold the partial tail for next time);
  only the codec's `decode/1` — which knows where a message ends — is protocol-specific.
  So the algorithm lives here, parameterised by a decode fn, and can't drift between
  block-fetch and chain-sync.

  `decode_fn.(binary)` follows the codec contract:
    * {:ok, msg, rest}  — a whole message + remaining bytes
    * :incomplete       — a valid-but-short prefix; carry it forward
    * {:error, reason}  — genuine corruption (not a short read)
  """
  use ExUnit.Case, async: true

  alias Cardamom.Mux.Reassembler

  # A trivial self-describing codec for the test: a message is one byte N (1..255)
  # followed by N payload bytes — i.e. <<N, payload::N-bytes>>. This lets us build
  # messages, split them anywhere, and check reassembly without depending on CBOR.
  defp decode(<<>>), do: :incomplete
  defp decode(<<0, _::binary>>), do: {:error, :zero_length}

  defp decode(<<n, rest::binary>>) when byte_size(rest) >= n do
    <<payload::binary-size(n), tail::binary>> = rest
    {:ok, payload, tail}
  end

  defp decode(<<_n, _short::binary>>), do: :incomplete

  defp msg(payload), do: <<byte_size(payload), payload::binary>>
  defp d, do: &decode/1

  test "a single whole message yields one message, empty buffer" do
    r = Reassembler.new()
    {msgs, r} = Reassembler.feed(r, msg("hello"), d())
    assert msgs == ["hello"]
    assert Reassembler.buffer(r) == <<>>
  end

  test "several whole messages in one feed all come out, empty buffer" do
    r = Reassembler.new()
    {msgs, r} = Reassembler.feed(r, msg("a") <> msg("bb") <> msg("ccc"), d())
    assert msgs == ["a", "bb", "ccc"]
    assert Reassembler.buffer(r) == <<>>
  end

  test "a message split across two feeds is reassembled (the 1962 invariant)" do
    full = msg("a long-ish payload")
    cut = div(byte_size(full), 2)
    <<head::binary-size(cut), tail::binary>> = full

    r = Reassembler.new()
    {msgs1, r} = Reassembler.feed(r, head, d())
    assert msgs1 == [], "the first half yields no whole message"
    refute Reassembler.buffer(r) == <<>>, "the partial tail is held"

    {msgs2, r} = Reassembler.feed(r, tail, d())
    assert msgs2 == ["a long-ish payload"]
    assert Reassembler.buffer(r) == <<>>, "buffer empties once the message completes"
  end

  test "a message split across THREE feeds is reassembled" do
    full = msg("threeway")
    <<a::binary-size(3), b::binary-size(3), c::binary>> = full

    r = Reassembler.new()
    {[], r} = Reassembler.feed(r, a, d())
    {[], r} = Reassembler.feed(r, b, d())
    {msgs, r} = Reassembler.feed(r, c, d())
    assert msgs == ["threeway"]
    assert Reassembler.buffer(r) == <<>>
  end

  test "a whole message glued to the START of the next: first out, tail carried" do
    whole = msg("first")
    next_full = msg("second message")
    cut = 4
    <<next_head::binary-size(cut), next_tail::binary>> = next_full

    r = Reassembler.new()
    {msgs1, r} = Reassembler.feed(r, whole <> next_head, d())
    assert msgs1 == ["first"]
    refute Reassembler.buffer(r) == <<>>

    {msgs2, r} = Reassembler.feed(r, next_tail, d())
    assert msgs2 == ["second message"]
    assert Reassembler.buffer(r) == <<>>
  end

  test "idle protocol has an empty buffer" do
    assert Reassembler.buffer(Reassembler.new()) == <<>>
  end

  test "genuine corruption surfaces as an error, does NOT silently carry over" do
    # A zero-length frame is corruption in our toy codec. feed/3 must report it, not
    # treat it as 'wait for more'. Whole messages that preceded it are still returned,
    # alongside the error so the caller can log/abort.
    r = Reassembler.new()
    # The whole "ok" message decodes; then the bad frame is a genuine error.
    assert {:error, ["ok"], {:error, :zero_length}} = Reassembler.feed(r, msg("ok") <> <<0, 1, 2>>, d())
  end
end
