import Config

config :openclaw, ecto_repos: [Openclaw.Repo]

config :openclaw, Openclaw.Repo,
  database: Path.expand("../openclaw_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 5

config :adk, ADK.Session.Store.Ecto, repo: Openclaw.Repo

import_config "#{config_env()}.exs"
