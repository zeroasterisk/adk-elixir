import Config

config :claw, Claw.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "claw_test_secret_key_base_that_is_at_least_64_bytes_long_for_security_purposes_ok",
  server: false

config :logger, level: :warning
