defmodule Cardamom.MixProject do
  use Mix.Project

  def project do
    [
      app: :cardamom,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      package: package()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.detail": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Cardamom.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # HTTP UI (hand-coded routes; no framework)
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.0"},
      {:jason, "~> 1.0"},
      # CBOR codec for mini-protocol message bodies
      {:cbor, "~> 1.0"},
      # BLAKE2b-256 — Cardano's hash for headers/tx-ids/addresses. (Erlang :crypto
      # only offers blake2b-512; blake2b-256 is a distinct parameterisation, not a
      # truncation, so we need a real impl.)
      {:blake2, "~> 1.0"},
      # Instrumentation event spine (logs + forensic store + UI subscribe to this)
      {:telemetry, "~> 1.0"},
      # Durable forensic store: Ecto + SQLite (the truth; survives restart, runs
      # analysis SQL). Postgres later = adapter swap.
      {:ecto_sql, "~> 3.0"},
      {:ecto_sqlite3, "~> 0.17"},
      # Hot in-memory working set in front of the durable store (ETS-backed,
      # read-through on miss). Eviction is harmless — bytes still live in SQLite.
      {:nebulex, "~> 2.6"},
      {:decorator, "~> 1.4"},
      # Property-based testing (codec round-trip + strict-parse properties)
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      # Coverage with annotated line-level HTML reports (mix coveralls.html)
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
