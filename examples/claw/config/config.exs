import Config

config :claw, Claw.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: Claw.ErrorHTML], layout: false],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Claw.PubSub,
  live_view: [signing_salt: "claw_salt_dev"]

config :claw,
  secret_key_base: "claw_dev_secret_key_base_that_is_at_least_64_bytes_long_for_security_purposes_ok"

# Use JsonFile session store — sessions survive restarts
config :adk,
  json_store_path: "priv/sessions"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
