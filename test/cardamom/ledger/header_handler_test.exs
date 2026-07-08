defmodule Cardamom.Ledger.HeaderHandlerTest do
  @moduledoc """
  The header PIPELINE gate (Ramsay's architecture: headers pass through a validation process
  BEFORE they take DB space). A HeaderHandler decodes → validates → stores, but stores ONLY on a
  pass. This pins the security-critical behaviour:

    * a VALID header is persisted (and the forest fed),
    * an INVALID header (bad opcert cold-key signature) is DROPPED — never persisted — and the
      sending peer's reputation is DOCKED.

  Non-foolable: the valid case uses a REAL Preview header (block 52578); the invalid case is the
  same header with a flipped signature byte, so decode still succeeds and ONLY validation rejects.
  """
  use Cardamom.DataCase, async: false
  import Bitwise, only: [bxor: 2]

  alias Cardamom.{ChainStore, Ledger.Header, Ledger.HeaderSupervisor, Store.Repo}
  alias Cardamom.Store.Header, as: HeaderRow
  alias Cardamom.Store.Peer

  @block_fixture Path.join([__DIR__, "..", "..", "fixtures", "preview_block_invalid_tx.hex"])

  # The raw header bytes (era 6) carved out of the real block, + its decoded form.
  defp real_header_raw do
    raw = @block_fixture |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
    {:ok, [_era, [hdr | _]], _} = CBOR.decode(raw)
    CBOR.encode(hdr)
  end

  # Tamper the real header so it still DECODES but its opcert cold-key signature FAILS: flip one
  # byte of the OPERATIONAL CERT's sigma and re-encode. The 10-field Praos header_body has the
  # opcert (a 4-list [hot_vkey, counter, kes_period, sigma]) at field index 8; sigma is element 3.
  # Only the sigma changes, so decode succeeds and ONLY validation rejects.
  defp tampered_header_raw do
    {:ok, [body, kes_sig], _} = CBOR.decode(real_header_raw())
    ocert = Enum.at(body, 8)
    %CBOR.Tag{tag: :bytes, value: sig} = Enum.at(ocert, 3)
    <<b0, rest::binary>> = sig
    bad_sig = %CBOR.Tag{tag: :bytes, value: <<bxor(b0, 1), rest::binary>>}
    bad_body = List.replace_at(body, 8, List.replace_at(ocert, 3, bad_sig))
    CBOR.encode([bad_body, kes_sig])
  end

  # Await the handler pid finishing (it exits :normal after store/drop). Bounded.
  defp await_handler(pid, timeout \\ 2_000) do
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> Process.demonitor(ref, [:flush]); :timeout
    end
  end

  test "a VALID header is decoded, validated, and STORED" do
    raw = real_header_raw()
    {:ok, h} = Header.decode(6, raw)

    {:ok, pid} = HeaderSupervisor.start_header(6, raw, nil)
    :ok = await_handler(pid)

    stored = Repo.get_by(HeaderRow, hash: h.hash)
    assert stored, "a valid header must be persisted"
    assert stored.slot == h.slot
  end

  test "an INVALID header (bad opcert signature) is NOT stored — the gate drops it" do
    bad_raw = tampered_header_raw()
    {:ok, bad_h} = Header.decode(6, bad_raw)

    assert {:invalid, _} = Cardamom.Ledger.Praos.Validation.verify_ocert(bad_h),
           "sanity: the tampered header must fail opcert validation"

    {:ok, pid} = HeaderSupervisor.start_header(6, bad_raw, nil)
    :ok = await_handler(pid)

    refute Repo.get_by(HeaderRow, hash: bad_h.hash),
           "an invalid header must NOT be persisted (the gate drops it)"
  end

  test "an invalid header from a known peer DOCKS the peer's reputation" do
    bad_raw = tampered_header_raw()
    peer = %{host: "1.2.3.4", port: 3001}
    # Seed the peer at a known quality so we can prove the delta lands.
    {:ok, _} = Repo.insert(%Peer{host: peer.host, port: peer.port, quality: 0})

    {:ok, pid} = HeaderSupervisor.start_header(6, bad_raw, peer)
    :ok = await_handler(pid)

    docked = Repo.get_by(Peer, host: peer.host, port: peer.port)
    assert docked.quality < 0, "a peer that sent an invalid/undecodable header is penalised"
  end
end
