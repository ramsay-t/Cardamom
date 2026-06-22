defmodule Cardamom.Protocol.BlockFetch.Codec do
  @moduledoc """
  Block-fetch mini-protocol (3) codec. Grammar (ouroboros-network
  BlockFetch/Codec.hs; tags are the leading CBOR-array integer):

      msgRequestRange = [0, point, point]   # client: fetch the inclusive range
      msgClientDone   = [1]                  # client: done
      msgStartBatch   = [2]                  # server: a batch follows
      msgNoBlocks     = [3]                  # server: I have none in that range
      msgBlock        = [4, #6.24(bytes)]    # server: one block, wrapCBORinCBOR-wrapped
      msgBatchDone    = [5]                  # server: batch complete

  A point on the wire is [slot, #bytes(hash)] or [] (origin) — same as chain-sync;
  point hashes are CBOR BYTE strings, NOT raw binaries (a raw binary encodes as text
  and the relay rejects it — see the chain-sync resume bug).

  The block in msgBlock is wrapped (CBOR tag 24 over the block bytes), exactly like
  chain-sync headers. We keep the block OPAQUE at the codec layer — decode returns
  the wrapped term; unwrapping to raw block bytes is the ledger/store layer's job.
  Strict: decode never raises, returns {:error, _} on anything unrecognised.
  """

  @type point :: [] | [non_neg_integer() | binary(), ...]
  @type message ::
          {:request_range, point(), point()}
          | :client_done
          | :start_batch
          | :no_blocks
          | {:block, term()}
          | :batch_done

  # ---- encode ----

  @spec encode(message()) :: binary()
  def encode({:request_range, from, to}),
    do: CBOR.encode([0, wire_point(from), wire_point(to)])

  def encode(:client_done), do: CBOR.encode([1])
  def encode(:start_batch), do: CBOR.encode([2])
  def encode(:no_blocks), do: CBOR.encode([3])
  def encode({:block, wrapped}), do: CBOR.encode([4, wrapped])
  def encode(:batch_done), do: CBOR.encode([5])

  # A point's hash must be a CBOR byte string (see moduledoc / the chain-sync bug).
  defp wire_point([slot, hash]) when is_integer(slot) and is_binary(hash),
    do: [slot, %CBOR.Tag{tag: :bytes, value: hash}]

  defp wire_point(other), do: other

  # ---- decode (strict; never raises) ----

  @spec decode(binary()) :: {:ok, message(), binary()} | :incomplete | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    case CBOR.decode(bytes) do
      {:ok, term, rest} ->
        with {:ok, msg} <- from_term(term), do: {:ok, msg, rest}

      {:error, e} ->
        # Distinguish "valid CBOR prefix, just truncated — wait for more bytes on this
        # channel" (:incomplete) from "genuinely malformed" ({:error, _}). A
        # mini-protocol message (a ~1KB block) can be split across SDU boundaries; the
        # client carries the partial tail forward and concatenates the next SDU. CBOR's
        # error atom (:cbor_match_error / :cbor_function_clause_error) does NOT reliably
        # mean truncation, so we decide STRUCTURALLY: does the CBOR head declare a frame
        # longer than what we hold? (See codec_test "incomplete" group; live bug
        # 2026-06-22 where a boundary split lost sync for the rest of the stream.)
        if truncated?(bytes), do: :incomplete, else: {:error, {:cbor, e}}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  # STRUCTURAL truncation check: read CBOR heads far enough to learn the declared total
  # length of the next item; if the buffer holds fewer bytes than that, it's a valid
  # prefix awaiting more (`:incomplete`), not corruption. We only need the shapes
  # block-fetch actually uses: an array `[tag, ...]`, ints (the tag), CBOR tag 24, and
  # byte/text strings (the wrapped block — the only item big enough to span SDUs).
  defp truncated?(bytes), do: needed(bytes) == :more

  # needed/1 returns :more if `bytes` is a valid-but-short prefix of a single CBOR item,
  # {:ok, rest} if a whole item is present (with the remaining bytes), or :bad if the
  # head itself is malformed (genuine corruption, not a short read).
  defp needed(<<>>), do: :more

  defp needed(<<mt::3, ai::5, rest::binary>> = _bin) do
    case {mt, ai} do
      # Major types 0/1 (uint/negint), 7 (simple/float): the value is in the head +
      # 0/1/2/4/8 follow bytes. A complete head means a complete item.
      {t, ai} when t in [0, 1, 7] -> consume_head_only(ai, rest)
      # Major type 2 (byte string) / 3 (text string): ai gives the length (or length-of-
      # length); the payload of that many bytes must follow.
      {t, ai} when t in [2, 3] -> consume_string(ai, rest)
      # Major type 4 (array): ai elements follow, each a full CBOR item.
      {4, ai} -> consume_array(ai, rest)
      # Major type 6 (tag, e.g. 24 wrapCBORinCBOR): the head, then one tagged item.
      {6, ai} -> consume_tag(ai, rest)
      # Major type 5 (map) — block-fetch never sends one; treat as bad.
      _ -> :bad
    end
  end

  # additional-info → number of length/value bytes that follow the head.
  defp ai_follow(ai) when ai < 24, do: {:inline, ai}
  defp ai_follow(24), do: {:bytes, 1}
  defp ai_follow(25), do: {:bytes, 2}
  defp ai_follow(26), do: {:bytes, 4}
  defp ai_follow(27), do: {:bytes, 8}
  defp ai_follow(_), do: :bad

  # uint/negint/simple: just the head's follow-bytes, no payload.
  defp consume_head_only(ai, rest) do
    case ai_follow(ai) do
      {:inline, _} -> {:ok, rest}
      {:bytes, n} -> if byte_size(rest) >= n, do: {:ok, binary_part(rest, n, byte_size(rest) - n)}, else: :more
      :bad -> :bad
    end
  end

  # byte/text string: read the declared length, then that many payload bytes.
  defp consume_string(ai, rest) do
    with {:ok, len, after_len} <- read_len(ai, rest) do
      if byte_size(after_len) >= len,
        do: {:ok, binary_part(after_len, len, byte_size(after_len) - len)},
        else: :more
    end
  end

  # array: read the count, then consume that many full items.
  defp consume_array(ai, rest) do
    with {:ok, count, after_len} <- read_len(ai, rest), do: consume_items(count, after_len)
  end

  # tag: head, then exactly one tagged item.
  defp consume_tag(ai, rest) do
    with {:ok, _tag, after_len} <- read_len(ai, rest), do: needed(after_len)
  end

  defp consume_items(0, rest), do: {:ok, rest}

  defp consume_items(n, rest) when n > 0 do
    case needed(rest) do
      {:ok, after_item} -> consume_items(n - 1, after_item)
      other -> other
    end
  end

  # Read a CBOR length/count from `ai` + any follow bytes; returns {:ok, value, rest}.
  defp read_len(ai, rest) when ai < 24, do: {:ok, ai, rest}

  defp read_len(ai, rest) do
    case ai_follow(ai) do
      {:bytes, n} ->
        if byte_size(rest) >= n do
          <<v::unsigned-size(n * 8), after_len::binary>> = rest
          {:ok, v, after_len}
        else
          :more
        end

      _ ->
        :bad
    end
  end

  defp from_term([0, from, to]), do: {:ok, {:request_range, from, to}}
  defp from_term([1]), do: {:ok, :client_done}
  defp from_term([2]), do: {:ok, :start_batch}
  defp from_term([3]), do: {:ok, :no_blocks}
  defp from_term([4, wrapped]), do: {:ok, {:block, wrapped}}
  defp from_term([5]), do: {:ok, :batch_done}
  defp from_term(other), do: {:error, {:unknown_block_fetch_message, other}}
end
