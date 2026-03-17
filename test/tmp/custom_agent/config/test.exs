import Config

# Use mock LLM backend in tests (no API key needed)
config :adk,
  llm_backend: ADK.LLM.Mock

config :logger, level: :warning
