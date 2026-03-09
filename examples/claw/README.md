# 🦀 Claw — ADK Elixir E2E Example

A minimal but real AI assistant built with [ADK Elixir](https://github.com/zeroasterisk/adk-elixir), exercising the full stack end-to-end.

## What it demonstrates

| Feature | Implementation |
|---------|---------------|
| **Multi-agent** | Router agent + coder + helper sub-agents |
| **Tool use** | 3 tools: `datetime`, `read_file`, `shell_command` (sandboxed) |
| **Session persistence** | JsonFile store (`priv/sessions/`) — survives restarts |
| **Callbacks** | `Claw.Callbacks` — logs all LLM calls |
| **A2A server** | Available at `/a2a` (JSON-RPC + agent card) |
| **Phoenix LiveView** | Chat UI at `/` using `ADK.Phoenix.ChatLive` |
| **Model** | `gemini-2.0-flash-lite` (cheapest) |

## Quick start

```bash
# 1. Set your Gemini API key
export GOOGLE_API_KEY="your-key-here"

# 2. Install dependencies
mix setup

# 3. Run tests
mix test

# 4. Start the server
mix phx.server
# or
iex -S mix phx.server
```

Then visit [http://localhost:4000](http://localhost:4000) for the chat UI.

### A2A endpoint

```bash
# Get agent card
curl http://localhost:4000/a2a/.well-known/agent.json

# Send a task
curl -X POST http://localhost:4000/a2a \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tasks/send","params":{"message":{"parts":[{"type":"text","text":"What time is it?"}]}}}'
```

## Project structure

```
examples/claw/
├── mix.exs                          # Dependencies (ADK as path dep)
├── config/                          # Phoenix config
├── lib/
│   ├── claw/
│   │   ├── application.ex           # OTP supervision tree
│   │   ├── agents.ex                # Agent definitions (router, coder, helper)
│   │   ├── tools.ex                 # 3 tools: datetime, read_file, shell_command
│   │   ├── callbacks.ex             # LLM call logging
│   │   ├── endpoint.ex              # Phoenix endpoint
│   │   ├── router.ex                # Routes: / (chat), /a2a (A2A protocol)
│   │   ├── layouts.ex               # Root HTML layout
│   │   └── error_html.ex            # Error pages
│   └── claw_web/
│       └── live/
│           └── chat_live.ex          # LiveView chat UI
├── test/
│   └── claw_test.exs                # Unit tests for agents, tools, callbacks
└── README.md
```

## ADK Elixir feedback

Things noticed while building this example:

1. **No ReflectRetry plugin exists yet** — The task spec asked for it, but there's no `ADK.Plugin.ReflectRetry` module. Would be useful to have a built-in plugin that retries failed LLM calls with reflection.

2. **Session store config is global** — `ADK.Session.Store.JsonFile` reads `base_path` from `Application.get_env(:adk, :json_store_path)`. This means you can't have different stores per runner. Consider allowing store config in `Runner` or `Session.start_link`.

3. **ChatLive uses `phx-update="append"`** — This is deprecated in LiveView 1.0+ in favor of streams. Should be updated.

4. **Runner.run/5 doesn't pass `session_store` through** — The `Runner` struct has a `session_store` field but it's never used in `Runner.run/5`. Sessions always go through `ADK.Session.start_supervised/1` which doesn't accept a store option from the runner.

5. **A2A Server as forward plug** — Works well! The Plug-based approach is clean. One note: the `init/1` creates a new ETS table on every init, which could be an issue if the plug is re-initialized.

6. **Multi-agent routing** — `LlmAgent` has a `sub_agents` field but the actual routing/delegation logic doesn't seem to be implemented yet. The LLM would need to use a "transfer" tool or similar mechanism to hand off to sub-agents. Currently sub_agents are defined but not automatically wired up.

7. **Missing `mix phx.server`** — The example uses `plug_cowboy` but Phoenix 1.7+ defaults to Bandit. Need to pick one adapter.
