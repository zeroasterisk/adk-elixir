import Config

config :claw, Claw.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "claw_dev_secret_key_base_that_is_at_least_64_bytes_long_for_security_purposes_ok",
  watchers: []

config :logger, :console, format: "[$level] $message\n"
