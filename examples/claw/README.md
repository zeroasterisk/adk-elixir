# Claw — ADK Elixir Showcase Agent

A full-featured chat agent built with ADK Elixir, demonstrating every major capability
of the stack. Think of it as the canonical end-to-end example.

## Quick Start

```bash
# Set your Gemini API key (or use GCP Application Default Credentials)
export GOOGLE_API_KEY="your-key"

# Install deps
mix deps.get

# Interactive CLI chat
mix claw.chat

# Phoenix LiveView UI
mix phx.server
# Open http://localhost:4000

# Run tests
mix test
```

## Features Showcased

| Feature | Where | Description |
|---------|-------|-------------|
| **LlmAgent + sub-agents** | `agents.ex` | Router delegates to Coder and Helper specialists |
| **Tools** | `tools.ex` | datetime, read_file, shell_command (sandboxed) |
| **Artifacts** | `tools.ex` | `save_note` / `list_notes` persist blobs via `ADK.Artifact.InMemory` |
| **Memory** | `agents.ex` | `ADK.Memory.InMemory` wired to runner for cross-session recall |
| **Auth/Credentials** | `tools.ex` | `call_mock_api` demonstrates `ADK.Auth.Credential` lifecycle |
| **LongRunningTool** | `tools.ex` | `research` tool streams progress updates via OTP `Task` |
| **Callbacks** | `callbacks.ex` | `ADK.Callback` logs every LLM call with before/after hooks |
| **RunConfig** | `agents.ex`, `cli.ex`, `chat_live.ex` | Temperature and max_tokens set at call time |
| **Eval** | `test/claw_eval_test.exs` | `ADK.Eval` suite with `Contains` and `ResponseLength` scorers |
| **LiveView UI** | `lib/claw_web/live/chat_live.ex` | Phoenix LiveView chat with temperature slider |
| **A2A** | `lib/claw_web/a2a_controller.ex` | Agent-to-Agent protocol endpoint |

## Architecture

```
Claw.Agents.router()         ← top-level LlmAgent
├── Claw.Agents.coder()      ← sub-agent: code/programming questions
└── Claw.Agents.helper()     ← sub-agent: general knowledge + datetime

Tools on router:
  datetime       → current UTC time
  read_file      → sandboxed file reader
  shell_command  → allowlisted shell runner
  save_note      → ADK.Artifact store (persist blobs)
  list_notes     → list saved artifacts
  call_mock_api  → ADK.Auth credential lifecycle demo
  research       → ADK.Tool.LongRunningTool (OTP process + progress updates)
```

## Artifacts

The `save_note` and `list_notes` tools demonstrate `ADK.Artifact`:

```elixir
# Tools use ToolContext.save_artifact/load_artifact
# Backed by ADK.Artifact.InMemory (started by ADK.Application)

# Try in chat:
"Save a note called 'Ideas' with content: Build more ADK examples"
"List my notes"
```

## Memory

The runner is configured with `ADK.Memory.InMemory` for cross-session recall:

```elixir
runner = ADK.Runner.new(
  app_name: "claw",
  agent: agent,
  memory_store: {ADK.Memory.InMemory, name: ADK.Memory.InMemory}
)
```

The memory store uses keyword matching to surface relevant past context.

## Auth / Credentials

The `call_mock_api` tool demonstrates the full credential lifecycle:

1. Try `ToolContext.load_credential/2` — look up existing credential
2. If `:not_found` — create a new `ADK.Auth.Credential.api_key/1` and save it
3. Use the credential for the API call

```elixir
# Try in chat:
"Call the weather endpoint of the mock API"
"Call the news endpoint"
"Call the prices endpoint"
```

## LongRunningTool

The `research` tool runs in a supervised OTP `Task` and streams progress updates.
This is the BEAM equivalent of Python ADK's `is_long_running = True`:

```elixir
LongRunningTool.new(:research,
  timeout: 30_000,
  func: fn _ctx, args, send_update ->
    send_update.("🔍 Starting research...")
    # ... work ...
    send_update.("✅ Compiling findings...")
    {:ok, summary}
  end
)
```

```
# Try in chat:
"Research the Elixir programming language"
"Research ADK with deep depth"
```

## RunConfig

Control generation parameters at runtime — from the CLI, LiveView, or code:

```elixir
# In code
run_config = Claw.Agents.run_config(temperature: 0.2, max_tokens: 512)
events = ADK.Runner.run(runner, user_id, session_id, input, run_config: run_config)

# Via environment variables (CLI)
CLAW_TEMP=0.9 CLAW_MAX_TOKENS=1024 mix claw.chat

# Via LiveView temperature slider (drag the slider in the UI)
```

## Eval

Run the agent through scenario-based evaluation with pluggable scorers:

```bash
mix test --only eval
```

Uses `ADK.LLM.Mock` (no API calls) with seeded responses:

```elixir
cases = [
  ADK.Eval.Case.new(
    name: "greeting_response",
    input: "Hello!",
    scorers: [
      {ADK.Eval.Scorer.Contains, text: "help", case_sensitive: false},
      {ADK.Eval.Scorer.ResponseLength, min: 10, max: 500}
    ]
  )
]

report = ADK.Eval.run(runner, cases)
IO.puts(ADK.Eval.Report.format(report))
```

## Files

| File | Purpose |
|------|---------|
| `lib/claw/agents.ex` | Agent definitions, runner, RunConfig helpers |
| `lib/claw/tools.ex` | All tools (basic + artifacts + auth + long-running) |
| `lib/claw/cli.ex` | stdin/stdout chat loop with RunConfig |
| `lib/claw/callbacks.ex` | LLM call logging |
| `lib/claw/application.ex` | OTP supervision tree (Phoenix + PubSub) |
| `lib/claw_web/live/chat_live.ex` | Phoenix LiveView chat with temperature slider |
| `lib/claw_web/a2a_controller.ex` | A2A protocol endpoint |
| `test/claw_test.exs` | Unit tests for all tools and agents |
| `test/claw_eval_test.exs` | ADK.Eval integration tests with scorers |

## Model

Uses `gemini-2.0-flash-lite` — cheapest available Gemini model, great for demos.
Change via `@model` in `lib/claw/agents.ex`.
