# Claw — ADK Elixir Chat Agent

A minimal OpenClaw-like chat agent built with ADK Elixir. Demonstrates the full stack:
LlmAgent, tools, sub-agents, callbacks, and a CLI interface.

## Quick Start

```bash
# Set your Gemini API key (or use GCP ADC)
export GOOGLE_API_KEY="your-key"

# Install deps
mix deps.get

# Chat via CLI
mix claw.chat

# Or start the Phoenix LiveView UI
mix phx.server
# Then open http://localhost:4000
```

## Architecture

- **Router agent** — top-level agent that delegates to specialists
- **Coder agent** — handles code/programming questions (has shell + file tools)
- **Helper agent** — general knowledge, datetime, file reading
- **Tools:** `datetime`, `read_file`, `shell_command` (sandboxed)
- **Model:** `gemini-2.0-flash-lite` (cheapest available)

## Files

| File | Purpose |
|------|---------|
| `lib/claw/agents.ex` | Agent definitions (router, coder, helper) |
| `lib/claw/tools.ex` | Tool implementations |
| `lib/claw/cli.ex` | stdin/stdout chat loop |
| `lib/claw/callbacks.ex` | LLM call logging |
| `lib/claw_web/live/chat_live.ex` | Phoenix LiveView chat UI |
