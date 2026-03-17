import Config

# ADK Configuration
config :custom_agent,
  model: "gemini-2.5-pro"

# Set your Gemini API key:
#   export GEMINI_API_KEY=your_key_here
config :adk,
  gemini_api_key: System.get_env("GEMINI_API_KEY")

import_config "#{config_env()}.exs"
