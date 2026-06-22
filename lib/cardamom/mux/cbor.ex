defmodule Cardamom.Mux.Cbor do
  @moduledoc """
  Structural CBOR-prefix detection, shared by the mini-protocol codecs.

  A mini-protocol message can be split across mux SDU boundaries. When `CBOR.decode/1`
  fails on a partial buffer, its error atom (`:cbor_match_error`,
  `:cbor_function_clause_error`, …) does NOT reliably distinguish "valid prefix, just
  truncated — wait for more bytes" from "genuinely malformed". So we decide
  STRUCTURALLY: walk the CBOR heads (which declare element counts and byte lengths) and
  see whether the buffer holds a whole top-level item.

  `complete?/1` answers: does `bytes` contain at least one WHOLE CBOR item at its head?
    * true  — a full item is present (possibly with trailing bytes — the next message)
    * false — the bytes are a valid-but-short PREFIX (truncated; carry over) OR empty.

  Malformed heads (bad additional-info) are reported as NOT complete only when they're
  also a plausible short read; a structurally-impossible head returns false too, but the
  caller still has CBOR.decode's `{:error, _}` to distinguish corruption — `complete?/1`
  is used precisely on the path where CBOR.decode already failed, to ask "was that a
  short read?". (See codec_test "incomplete" groups; live block-fetch bug 2026-06-22.)

  Handles every CBOR major type: 0/1 uint/negint, 2/3 byte/text string, 4 array,
  5 map, 6 tag, 7 simple/float — definite and indefinite (break-terminated) lengths.
  """

  @doc "Is at least one whole CBOR item present at the head of `bytes`?"
  @spec complete?(binary()) :: boolean()
  def complete?(bytes) when is_binary(bytes) do
    case item(bytes) do
      {:ok, _rest} -> true
      _ -> false
    end
  end

  # item/1 returns {:ok, rest} if a whole CBOR item is present (rest = trailing bytes),
  # :more if `bytes` is a valid-but-short prefix, or :bad if a head is malformed.
  defp item(<<>>), do: :more

  defp item(<<mt::3, ai::5, rest::binary>>) do
    case mt do
      t when t in [0, 1, 7] -> head_only(ai, rest)
      t when t in [2, 3] -> string(ai, rest)
      4 -> collection(ai, rest, 1)
      5 -> collection(ai, rest, 2)
      6 -> tag(ai, rest)
      _ -> :bad
    end
  end

  # additional-info → how the length/value is carried.
  defp ai_follow(ai) when ai < 24, do: {:inline, ai}
  defp ai_follow(24), do: {:bytes, 1}
  defp ai_follow(25), do: {:bytes, 2}
  defp ai_follow(26), do: {:bytes, 4}
  defp ai_follow(27), do: {:bytes, 8}
  defp ai_follow(31), do: :indefinite
  defp ai_follow(_), do: :bad

  # uint/negint/simple/float: value is in the head + follow bytes, no payload.
  defp head_only(ai, rest) do
    case ai_follow(ai) do
      {:inline, _} -> {:ok, rest}
      {:bytes, n} -> drop(rest, n)
      # MT 7 ai=31 is the CBOR "break" stop-code — a whole one-byte item here.
      :indefinite -> {:ok, rest}
      :bad -> :bad
    end
  end

  # byte/text string: read the declared length, then that many payload bytes. An
  # indefinite-length string is a sequence of definite chunks ended by a break.
  defp string(31, rest), do: until_break(rest)

  defp string(ai, rest) do
    with {:ok, len, after_len} <- read_len(ai, rest), do: drop(after_len, len)
  end

  # array (n=1 item per element) / map (n=2 items per pair): read the count, then
  # consume count*n full items. Indefinite → consume items until a break.
  defp collection(31, rest, _n), do: until_break(rest)

  defp collection(ai, rest, n) do
    with {:ok, count, after_len} <- read_len(ai, rest), do: items(count * n, after_len)
  end

  # tag: head, then exactly one tagged item.
  defp tag(ai, rest) do
    with {:ok, _tag, after_len} <- read_len(ai, rest), do: item(after_len)
  end

  defp items(0, rest), do: {:ok, rest}

  defp items(n, rest) when n > 0 do
    case item(rest) do
      {:ok, after_item} -> items(n - 1, after_item)
      other -> other
    end
  end

  # Consume CBOR items until the break stop-code (0xFF) — for indefinite-length items.
  defp until_break(<<0xFF, rest::binary>>), do: {:ok, rest}
  defp until_break(<<>>), do: :more

  defp until_break(bytes) do
    case item(bytes) do
      {:ok, after_item} -> until_break(after_item)
      other -> other
    end
  end

  # Read a definite length/count from ai + follow bytes.
  defp read_len(ai, rest) when ai < 24, do: {:ok, ai, rest}

  defp read_len(ai, rest) do
    case ai_follow(ai) do
      {:bytes, n} ->
        case rest do
          <<v::unsigned-size(n * 8), after_len::binary>> -> {:ok, v, after_len}
          _ -> :more
        end

      _ ->
        :bad
    end
  end

  # Drop `n` payload bytes; :more if fewer than n are present.
  defp drop(bin, n) when byte_size(bin) >= n,
    do: {:ok, binary_part(bin, n, byte_size(bin) - n)}

  defp drop(_bin, _n), do: :more
end
