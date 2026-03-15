import Config

config :openclaw, Openclaw.Repo,
  database: Path.expand("../openclaw_test.db", Path.dirname(__ENV__.file)),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5
