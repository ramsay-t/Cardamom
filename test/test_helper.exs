# The application (auto-started in :test) brings up Store.Repo + Store.Cache and runs
# migrations on boot. DB-touching tests isolate via a clean slate per test (truncate
# + cache wipe in Cardamom.DataCase), not the sandbox — app-singleton processes share
# this one Repo, and sandbox shared-mode let their writes escape and leak between tests.
# Delete the throwaway test store DIR (forest-<test-magic>.db + WAL/SHM sidecars live
# in it) after the whole suite, so we never leave stale test stores in tmp.
ExUnit.after_suite(fn _result ->
  db = Application.get_env(:cardamom, Cardamom.Store.Repo)[:database]
  if is_binary(db), do: File.rm_rf(Path.dirname(db))
end)

ExUnit.start()
