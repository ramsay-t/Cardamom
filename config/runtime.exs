import Config

# runtime.exs runs at BOOT (in a release, every start) — NOT at compile time. This is
# where a deployed Cardamom reads its environment, so ONE release artifact runs anywhere
# (garage box, AWS) by env var alone, with the chain DB living outside the release dir.
#
# Env vars (all optional; sensible Preview defaults):
#   CARDAMOM_DATA_DIR — absolute dir for the chain DB (forest-<magic>.db). MUST be stable
#                       across upgrades (it's the resume point). Default: "data" (relative).
#   CARDAMOM_NETWORK  — network magic (2 = Preview). Mainnet (764824073) is refused.
#   CARDAMOM_PORT     — the read-only HTTP UI port (default 4001).
#
# In :test we leave config alone (config.exs already wires a throwaway tmp DB).
if config_env() != :test do
  if data_dir = System.get_env("CARDAMOM_DATA_DIR") do
    config :cardamom, :data_dir, data_dir
  end

  # The repo's `database:` is also bound at boot by Application.configure_store_db/0 from
  # the network magic; setting :data_dir above is what relocates it for prod.
end
