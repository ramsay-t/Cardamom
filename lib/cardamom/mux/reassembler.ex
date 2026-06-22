defmodule Cardamom.Mux.Reassembler do
  @moduledoc """
  The generic message-reassembly carry-over shared by every mini-protocol client.

  A mini-protocol message can be SPLIT across mux SDU boundaries (a ~1KB block spans
  several SDUs), and conversely several WHOLE messages can be PACKED into one SDU (a
  relay glues the last block + BatchDone). The algorithm that copes with both is the
  same for all protocols:

    1. concatenate the carried-over tail with the new SDU payload;
    2. decode every WHOLE message;
    3. hold the trailing partial message (`:incomplete`) for the next SDU.

  Only the codec's `decode/1` — which knows where a message ends — is
  protocol-specific, so it's passed in. This is the home of the reassembly logic so it
  CANNOT drift between block-fetch and chain-sync (and any future protocol gets it for
  free by using this). The bearer stays protocol-agnostic (routes by number, never
  interprets payloads — the Harvard boundary); message-boundary knowledge lives in the
  codec, and the buffering that drives it lives here.

  `buffer` is empty whenever the protocol is between whole messages (idle); a non-empty
  buffer means a message is in flight across SDUs.

  The `decode_fn` follows the codec contract:
    * `{:ok, msg, rest}` — a whole message + the remaining bytes
    * `:incomplete`      — a valid-but-short prefix; carry it forward, wait for more
    * `{:error, reason}` — genuine corruption (NOT a short read)
  """

  @enforce_keys [:buffer]
  defstruct buffer: <<>>

  @type t :: %__MODULE__{buffer: binary()}
  @type decode_result :: {:ok, term(), binary()} | :incomplete | {:error, term()}
  @type decode_fn :: (binary() -> decode_result())

  @doc "A fresh reassembler with an empty carry-over buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{buffer: <<>>}

  @doc "The current carry-over buffer (empty ⇔ no message in flight)."
  @spec buffer(t()) :: binary()
  def buffer(%__MODULE__{buffer: b}), do: b

  @doc """
  Feed one SDU payload. Prepends the carried-over tail, decodes every whole message,
  and holds any trailing partial message for next time.

  Returns:
    * `{messages, reassembler}` — the whole messages decoded (in order), and the
      reassembler carrying the partial tail (if any);
    * `{:error, messages, reason}` — genuine corruption was hit; `messages` are the
      whole messages decoded BEFORE the bad bytes, `reason` is the decode error. The
      caller decides what to do (log/abort) — we don't silently swallow corruption as
      "wait for more".
  """
  @spec feed(t(), binary(), decode_fn()) ::
          {[term()], t()} | {:error, [term()], {:error, term()}}
  def feed(%__MODULE__{buffer: buf}, payload, decode_fn) when is_function(decode_fn, 1) do
    drain(buf <> payload, decode_fn, [])
  end

  # Decode whole messages until the bytes run out (empty), are a partial prefix
  # (:incomplete → carry over), or are corrupt ({:error} → surface with what we have).
  defp drain(<<>>, _decode_fn, acc), do: {Enum.reverse(acc), %__MODULE__{buffer: <<>>}}

  defp drain(bytes, decode_fn, acc) do
    case decode_fn.(bytes) do
      {:ok, msg, rest} -> drain(rest, decode_fn, [msg | acc])
      :incomplete -> {Enum.reverse(acc), %__MODULE__{buffer: bytes}}
      {:error, _reason} = err -> {:error, Enum.reverse(acc), err}
    end
  end
end
