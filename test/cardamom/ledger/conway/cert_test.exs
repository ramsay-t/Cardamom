defmodule Cardamom.Ledger.Conway.CertTest do
  @moduledoc """
  Conway certificate decoding (crypto-free structural typing). Non-foolable where possible: the
  real-data test decodes block 16's actual registration+delegation certs. Synthetic cases cover
  the tags Preview's early fixtures don't exercise (DRep/committee/combined), built to the exact
  conway.cddl shapes.
  """
  use ExUnit.Case, async: true

  alias Cardamom.Ledger.Conway.{Cert, Tx}

  defp bytes(b), do: %CBOR.Tag{tag: :bytes, value: b}
  defp key_cred(h), do: [0, bytes(h)]

  test "REAL: block 16 decodes to stake_registration + pool_registration + stake_delegation" do
    raw = Path.join([__DIR__, "..", "..", "..", "fixtures", "blocks", "block-16.hex"])
          |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
    {:ok, [t16]} = Tx.txs_in(raw)
    types = t16.certs |> Cert.decode_all() |> Enum.map(& &1.type)

    assert :stake_registration in types
    assert :pool_registration in types
    assert :stake_delegation in types
  end

  test "REAL: a decoded pool_registration has the full pool_params" do
    raw = Path.join([__DIR__, "..", "..", "..", "fixtures", "blocks", "block-16.hex"])
          |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
    {:ok, [t16]} = Tx.txs_in(raw)
    reg = t16.certs |> Cert.decode_all() |> Enum.find(& &1.type == :pool_registration)

    assert byte_size(reg.params.operator) == 28
    assert byte_size(reg.params.vrf_keyhash) == 32
    assert is_integer(reg.params.pledge)
    assert is_integer(reg.params.cost)
    assert match?({_n, _d}, reg.params.margin)
    assert is_list(reg.params.owners)
  end

  test "credential decodes key vs script (via a stake-registration cert)" do
    # tag 7 = stake_registration(credential, coin); the credential is itself [0|1, hash].
    assert %{credential: {:key, "kh"}} = Cert.decode([7, [0, bytes("kh")], 0])
    assert %{credential: {:script, "sh"}} = Cert.decode([7, [1, bytes("sh")], 0])
  end

  test "stake reg/unreg with and without explicit deposit (tags 0/1/7/8)" do
    assert %{type: :stake_registration, deposit: nil} = Map.put_new(Cert.decode(key_reg(0)), :deposit, nil)
    assert %{type: :stake_registration, deposit: 2_000_000} = Cert.decode([7, key_cred("c"), 2_000_000])
    assert %{type: :stake_deregistration} = Cert.decode([1, key_cred("c")])
    assert %{type: :stake_deregistration, refund: 2_000_000} = Cert.decode([8, key_cred("c"), 2_000_000])
  end

  test "delegation (2), vote delegation (9 → drep variants)" do
    assert %{type: :stake_delegation, pool: "pool"} = Cert.decode([2, key_cred("c"), bytes("pool")])
    assert %{type: :vote_delegation, drep: {:key, "d"}} = Cert.decode([9, key_cred("c"), [0, bytes("d")]])
    assert %{type: :vote_delegation, drep: :abstain} = Cert.decode([9, key_cred("c"), [2]])
    assert %{type: :vote_delegation, drep: :no_confidence} = Cert.decode([9, key_cred("c"), [3]])
  end

  test "combined register+delegate certs (10-13)" do
    assert %{type: :stake_and_vote_delegation, pool: "p", drep: :abstain} =
             Cert.decode([10, key_cred("c"), bytes("p"), [2]])
    assert %{type: :stake_registration_and_delegation, pool: "p", deposit: 5} =
             Cert.decode([11, key_cred("c"), bytes("p"), 5])
    assert %{type: :vote_registration_and_delegation, drep: {:key, "d"}, deposit: 5} =
             Cert.decode([12, key_cred("c"), [0, bytes("d")], 5])
    assert %{type: :stake_vote_registration_and_delegation, pool: "p", deposit: 5} =
             Cert.decode([13, key_cred("c"), bytes("p"), [2], 5])
  end

  test "DRep certs (16/17/18) and committee certs (14/15)" do
    assert %{type: :drep_registration, deposit: 500, anchor: nil} = Cert.decode([16, key_cred("d"), 500, nil])
    assert %{type: :drep_registration, anchor: %{url: "u"}} = Cert.decode([16, key_cred("d"), 500, ["u", bytes("h")]])
    assert %{type: :drep_deregistration, refund: 500} = Cert.decode([17, key_cred("d"), 500])
    assert %{type: :drep_update} = Cert.decode([18, key_cred("d"), nil])
    assert %{type: :committee_hot_auth, cold: {:key, "cold"}, hot: {:key, "hot"}} =
             Cert.decode([14, key_cred("cold"), key_cred("hot")])
    assert %{type: :committee_resignation, cold: {:key, "cold"}} = Cert.decode([15, key_cred("cold"), nil])
  end

  test "an unknown/future cert tag decodes to :unknown, never crashes" do
    assert %{type: :unknown, tag: 99} = Cert.decode([99, "whatever"])
    assert %{type: :unknown} = Cert.decode("not even a list")
  end

  # ---- MC/DC: decoder clauses only hit via the real fixture, asserted directly ----

  test "tag 0 stake_registration (no explicit deposit) decodes" do
    assert %{type: :stake_registration, credential: {:key, "c"}} = Cert.decode([0, key_cred("c")])
    refute Map.has_key?(Cert.decode([0, key_cred("c")]), :deposit)
  end

  test "tag 3 pool_registration decodes the full pool_params tuple" do
    params = [
      bytes("op"), bytes("vrf"), 100, 5, %CBOR.Tag{tag: 30, value: [1, 10]},
      bytes("reward"), [bytes("owner")], [], nil
    ]
    assert %{type: :pool_registration, params: p} = Cert.decode([3 | params])
    assert p.operator == "op"
    assert p.margin == {1, 10}
    assert p.owners == ["owner"]
  end

  test "tag 4 pool_retirement decodes pool + epoch" do
    assert %{type: :pool_retirement, pool: "p", epoch: 42} = Cert.decode([4, bytes("p"), 42])
  end

  test "malformed sub-structures decode defensively (never crash)" do
    # A credential that's neither [0,_] nor [1,_]
    assert %{credential: {:unknown, _}} = Cert.decode([7, [9, bytes("x")], 0])
    # A drep with an unknown tag
    assert %{drep: {:unknown, _}} = Cert.decode([9, key_cred("c"), [9]])
    # A pool_params that isn't the 9-field tuple
    assert %{params: %{malformed: _}} = Cert.decode([3, "not-params"])
  end

  defp key_reg(0), do: [0, key_cred("c")]
end
