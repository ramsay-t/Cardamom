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
        # STRUCTURAL truncation check (shared) — a valid-but-short CBOR prefix means a
        # message split across SDU boundaries; the client carries the tail forward.
        if Cardamom.Mux.Cbor.complete?(bytes), do: {:error, {:cbor, e}}, else: :incomplete
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  defp from_term([0, from, to]), do: {:ok, {:request_range, from, to}}
  defp from_term([1]), do: {:ok, :client_done}
  defp from_term([2]), do: {:ok, :start_batch}
  defp from_term([3]), do: {:ok, :no_blocks}
  defp from_term([4, wrapped]), do: {:ok, {:block, wrapped}}
  defp from_term([5]), do: {:ok, :batch_done}
  defp from_term(other), do: {:error, {:unknown_block_fetch_message, other}}
end
