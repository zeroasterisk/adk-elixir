# ADK Elixir — Developer Guide

Setup, workflow, testing, and contributing.

---

## Requirements

- Elixir ~> 1.14 (1.16+ recommended)
- Erlang/OTP 26+
- `mix` (bundled with Elixir)

---

## Getting Started

### New Project from Scratch

```bash
mix adk.new my_agent_app
cd my_agent_app
mix deps.get
mix test
```

The scaffold generates:

```
my_agent_app/
├── lib/
│   ├── my_agent_app/
│   │   └── agent.ex        # your first LlmAgent
│   └── my_agent_app.ex
├── test/
│   └── my_agent_app/
│       └── agent_test.exs
├── config/
│   └── config.exs          # LLM backend config
└── mix.exs
```

### Add ADK to an Existing Project

```elixir
# mix.exs
defp deps do
  [
    {:adk, "~> 0.1.0"}
  ]
end
```

```bash
mix deps.get
```

---

## Configuration

```elixir
# config/config.exs
import Config

# LLM backend (required)
config :adk, :llm_backend, ADK.LLM.Gemini
config :adk, :gemini_api_key, System.get_env("GEMINI_API_KEY")

# Optional: persist sessions
config :adk, :default_session_store, {ADK.Session.Store.ETS, []}

# config/test.exs
import Config
config :adk, :llm_backend, ADK.LLM.Mock
```

---

## Project Structure (Library)

```
lib/
├── adk/
│   ├── agent/
│   │   ├── llm_agent.ex          # core LLM agent
│   │   ├── sequential_agent.ex   # chains agents
│   │   ├── parallel_agent.ex     # fan-out
│   │   ├── loop_agent.ex         # iterate
│   │   └── remote_a2a_agent.ex   # A2A remote delegation
│   ├── runner.ex                 # execution orchestrator
│   ├── session.ex                # session lifecycle
│   ├── callback.ex               # callback behaviour
│   ├── tool.ex                   # tool behaviour
│   ├── eval.ex                   # evaluation framework
│   ├── telemetry.ex              # telemetry events
│   └── telemetry/
│       ├── contract.ex           # canonical event contract
│       ├── debug_handler.ex      # span capture handler
│       └── span_store.ex         # ETS-backed span store
test/
├── adk/
│   ├── runner_test.exs
│   ├── callback_test.exs
│   └── agent/
│       └── llm_agent_test.exs
└── support/
    └── mock_llm.ex               # ADK.LLM.Mock helpers
```

---

## Development Workflow

### Build and Check

```bash
mix deps.get                           # install deps
mix compile                            # compile
mix compile --warnings-as-errors       # strict — must be clean for PRs
mix format                             # auto-format (runs Elixir formatter)
mix format --check-formatted           # CI check
```

### Run Tests

```bash
mix test                               # all tests
mix test --trace                       # verbose (show each test name)
mix test test/adk/runner_test.exs      # single file
mix test test/adk/runner_test.exs:42   # single line
mix test --failed                      # only re-run failures
mix test --seed 0                      # deterministic order
```

### Generate Docs

```bash
mix docs
open doc/index.html
```

---

## Writing Tests

### Setup with Mock LLM

```elixir
defmodule MyApp.AgentTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.Runner

  setup do
    agent = LlmAgent.new(
      name: "test_agent",
      model: "test",
      instruction: "You are a test assistant."
    )
    runner = Runner.new(app_name: "test", agent: agent)
    %{agent: agent, runner: runner}
  end

  test "returns events for a simple message", %{runner: runner} do
    # ADK.LLM.Mock auto-responds in test env
    events = Runner.run(runner, "u1", "sess1", "hello")
    assert is_list(events)
    assert length(events) > 0
  end
end
```

### Mock LLM Responses

`ADK.LLM.Mock` (the default test backend) returns a simple text response. To
control what the mock returns, configure it in `config/test.exs` or use
`Application.put_env/3` in your test setup:

```elixir
setup do
  Application.put_env(:adk, :mock_llm_response, %{
    content: %{parts: [%{text: "custom response"}]}
  })
  on_exit(fn -> Application.delete_env(:adk, :mock_llm_response) end)
  :ok
end
```

### Testing Callbacks

```elixir
test "before_agent callback can halt", %{runner: runner} do
  halt_cb = %{
    before_agent: fn _ctx -> {:halt, []} end
  }

  events = Runner.run(runner, "u1", "s1", "hi", callbacks: [halt_cb])
  assert events == []
end
```

---

## Contributing

### Code Style

- `mix format` before committing (enforced in CI)
- `mix compile --warnings-as-errors` must be clean
- No unused variables/aliases (Elixir will warn — treat as errors)
- Module docs (`@moduledoc`) required for public modules
- Function docs (`@doc`) required for public functions
- Typespecs (`@spec`) encouraged for all public functions

### Test Requirements

- All new code needs tests
- `mix test` must pass (no new failures)
- Test file mirrors lib path: `lib/adk/foo.ex` → `test/adk/foo_test.exs`
- Use `async: true` unless you need shared state
- Use `ADK.LLM.Mock` for LLM-dependent tests — never call real LLMs in tests

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add output_schema validation to LlmAgent
fix: handle nil content in LLM response
test: add parity tests for base_agent callbacks
docs: update cheatsheet with loop agent example
refactor: extract tool execution into separate module
```

### Pull Request Checklist

- [ ] `mix compile --warnings-as-errors` clean
- [ ] `mix format --check-formatted` passes
- [ ] `mix test` passes (no regressions)
- [ ] New public functions have `@doc` and `@spec`
- [ ] CHANGELOG.md updated (if user-facing change)

---

## Common Patterns

### Supervisor Integration

```elixir
# lib/my_app/application.ex
children = [
  {Registry, keys: :unique, name: ADK.Session.Registry},
  {DynamicSupervisor, name: ADK.Session.Supervisor, strategy: :one_for_one},
  ADK.Telemetry.SpanStore,
  # your app children...
]

Supervisor.start_link(children, strategy: :one_for_one)
```

ADK.Application manages its own supervision tree when used as a library — you
typically only need to add ADK children if you're embedding them manually.

### Phoenix Integration

See [Phoenix Integration docs](https://zeroasterisk.github.io/adk-elixir/phoenix-integration.html).

```elixir
# lib/my_app_web/controllers/chat_controller.ex
def create(conn, %{"message" => text}) do
  runner = MyApp.runner()
  events = ADK.Runner.run(runner, conn.assigns.user_id, session_id(conn), text)
  text = ADK.Eval.Scorer.response_text(events)
  json(conn, %{reply: text})
end
```

---

## Debugging

### Dev Server

```bash
# Start the ADK dev web UI (inspect sessions, events, spans)
iex -S mix run --no-halt
# or with Phoenix:
iex -S mix phx.server
```

Visit `http://localhost:4000/adk/debug` to inspect sessions and telemetry spans.

### IEx Exploration

```bash
iex -S mix
```

```elixir
alias ADK.{Runner, Agent.LlmAgent}

agent = LlmAgent.new(name: "bot", model: "test", instruction: "help")
runner = Runner.new(app_name: "dev", agent: agent)
events = Runner.run(runner, "me", "s1", "hello")
events |> Enum.map(& &1.content)
```
