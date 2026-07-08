defmodule Cardamom.Ledger.HeaderHandler do
  @moduledoc """
  The per-HEADER pipeline handler: receive → DECODE → VALIDATE → STORE, as a supervised BEAM
  process (one per header). Mirrors `Cardamom.Ledger.BlockHandler`. Chain-sync hands each
  RollForward header here; the handler:

    1. DECODES the era-tagged raw bytes (era-dispatching ledger decoder),
    2. VALIDATES it (Praos header checks — currently the operational-cert cold-key signature; more
       tiers to come),
    3. STORES it (feed the forest + persist to the durable store) — ONLY if 1 AND 2 pass.

  THE GATE (Ramsay's architecture: "headers sit in a validation process before they go into the DB
  and take up space"). A header that fails to decode or validate is DROPPED — never persisted, so
  a peer can't fill our disk with junk headers — and the offending peer's reputation is DOCKED
  (record_peer sent_undecodable_header / sent_invalid_header) plus a loud log line. Then the
  handler exits :normal (its work is done, pass or drop).

  Validation is currently a hook that runs the crypto checks we CAN do header-only (opcert). Checks
  needing the parent header (chain continuity) or external state (VRF stake/nonce) are TODO and
  will slot into `validate/1` as they land.
  """
  use GenServer
  require Logger

  alias Cardamom.Ledger.{HeaderRegistry, Header, Praos.Validation}
  alias Cardamom.ChainStore

  def start_link({key, _era, _raw, _peer} = arg) when is_binary(key) do
    GenServer.start_link(__MODULE__, arg, name: {:via, Registry, {HeaderRegistry, key}})
  end

  @impl true
  def init({key, era, raw, peer}) do
    {:ok, %{key: key, era: era, raw: raw, peer: peer}, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, %{era: era, raw: raw, peer: peer} = st) do
    case Header.decode(era, raw) do
      {:ok, h} ->
        case validate(h) do
          :ok ->
            store(h, raw)
            emit("HeaderStored", header_meta(h, era, raw))
            {:stop, :normal, st}

          {:invalid, reason} ->
            Logger.warning("header REJECTED (invalid) era=#{era} hash=#{h.hash_hex} reason=#{inspect(reason)}")
            emit("HeaderRejected", Map.merge(header_meta(h, era, raw), %{rejected: :invalid, reason: inspect(reason)}))
            dock(peer, :sent_invalid_header)
            {:stop, :normal, st}
        end

      {:error, reason} ->
        Logger.warning("header REJECTED (undecodable) era=#{era} reason=#{inspect(reason)}")
        emit("HeaderRejected", %{header_era: era, rejected: :undecodable, reason: inspect(reason), header_bytes: byte_size(raw)})
        dock(peer, :sent_undecodable_header)
        {:stop, :normal, st}
    end
  end

  # Rich telemetry for a decoded header — the observability that used to live on chain-sync's
  # RollForward event, now emitted here (this is where decoding happens).
  defp header_meta(h, era, raw) do
    %{
      header_era: era,
      header_hash: h.hash_hex,
      header_slot: h.slot,
      header_block: h.block_number,
      header_prev: prev_hex(h.prev_hash),
      header_bytes: byte_size(raw)
    }
  end

  defp emit(msg, extra) do
    :telemetry.execute([:cardamom, :protocol, :event], %{count: 1}, Map.merge(%{protocol: "header", msg: msg}, extra))
  end

  # ---- VALIDATE: the gate. Returns :ok | {:invalid, reason}. ----
  # Currently the header-only crypto check we have (operational-cert cold-key signature). Byron
  # headers have no opcert (nil) → nothing to check here yet (Byron validation is a separate story).
  defp validate(%{operational_cert: nil}), do: :ok

  defp validate(h) do
    Validation.verify_ocert(h)
  end

  # ---- STORE: only reached on a PASS. Mark re-extract, feed the forest, persist. ----
  defp store(h, raw) do
    # A (re)seen VALID header invalidates any stale "done" state for its block: reset
    # txo_processed=false so the reconciler re-extracts it (header is the source of truth). Moved
    # here from chain-sync — it needs the decoded hash and must only fire for a VALIDATED header.
    mark_block_for_reextract(h.hash_hex)

    if Process.whereis(Cardamom.Forest.Server) do
      Cardamom.Forest.Server.add_header(h.hash_hex, prev_hex(h.prev_hash))
    end

    if Process.whereis(Cardamom.Store.Repo) do
      ChainStore.put_decoded_header(h, raw)
    end

    :ok
  rescue
    e -> Logger.warning("header store failed: #{inspect(e)}")
  end

  defp mark_block_for_reextract(hex) when is_binary(hex) do
    with {:ok, bin} <- Base.decode16(hex, case: :lower),
         true <- Process.whereis(Cardamom.ChainStore) != nil do
      ChainStore.mark_block_unprocessed(bin)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp prev_hex(nil), do: nil
  defp prev_hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  # Dock the peer that sent a bad header (best-effort; peer may be nil in tests / early boot).
  defp dock(%{host: host, port: port}, event) when is_integer(port) do
    if Process.whereis(Cardamom.ChainStore),
      do: ChainStore.record_peer(%{host: host, port: port, event: event})
  rescue
    _ -> :ok
  end

  defp dock(_peer, _event), do: :ok
end
