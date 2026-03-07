# ADK Elixir

[![CI](https://github.com/zeroasterisk/adk-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/zeroasterisk/adk-elixir/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue)](https://zeroasterisk.github.io/adk-elixir)

**Agent Development Kit for Elixir** — an OTP-native agent framework inspired by [Google ADK](https://github.com/google/adk-python).

> ⚠️ Early prototype. API will change. Not yet published to Hex.

## Why Elixir?

ADK Python and ADK Go are solid, but Elixir's runtime was _built_ for this:

- **Agents are processes.** OTP supervision trees mirror agent hierarchies — crash isolation, restart strategies, and circuit breaking for free.
- **Streaming is native.** `Stream` + Phoenix PubSub replace custom async generators and channel implementations.
- **State is isolated.** Process boundaries eliminate shared-state bugs. No locks, no mutexes.
- **Fault tolerance is built-in.** "Let it crash" + supervisors means agents recover automatically from transient failures.

## Quick Start

```elixir
# mix.exs
{:adk, github: "zeroasterisk/adk-elixir"}
```

```elixir
# Create an agent
agent = ADK.new("assistant",
  model: "gemini-2.0-flash",
  instruction: "You are a helpful assistant."
)

# Chat (blocking, returns text)
ADK.chat(agent, "What is Elixir?")
#=> "Elixir is a dynamic, functional language designed for building scalable..."

# Run (returns events for full control)
events = ADK.run(agent, "Tell me about OTP")
```

## Using a Real LLM (Gemini)

By default, ADK uses a mock LLM for testing. To use Google's Gemini API:

```elixir
# config/config.exs (or config/runtime.exs)
config :adk, :llm_backend, ADK.LLM.Gemini
config :adk, :gemini_api_key, System.get_env("GEMINI_API_KEY")
```

Or set the `GEMINI_API_KEY` environment variable and configure the backend:

```elixir
config :adk, :llm_backend, ADK.LLM.Gemini
```

Then use ADK as normal — all agents will use Gemini:

```elixir
agent = ADK.new("assistant",
  model: "gemini-2.0-flash",
  instruction: "You are a helpful assistant."
)

ADK.chat(agent, "What is Elixir?")
#=> "Elixir is a dynamic, functional language..."
```

## Agents

### LLM Agent

The core agent — sends messages to an LLM, handles tool calls, returns events.

```elixir
agent = ADK.new("researcher",
  model: "gemini-2.0-flash",
  instruction: "You research topics thoroughly.",
  tools: [&MyTools.search/1, &MyTools.summarize/1]
)
```

### Sequential Agent

Chains agents in sequence — output of one feeds into the next.

```elixir
pipeline = ADK.sequential([
  ADK.new("researcher", instruction: "Find relevant information."),
  ADK.new("writer", instruction: "Write a clear summary from the research.")
])

ADK.chat(pipeline, "Explain BEAM concurrency")
```

## Tools

### Function Tools

Any function becomes a tool:

```elixir
# Arity-1: receives args map
def get_weather(%{"city" => city}) do
  %{temp: 72, condition: "sunny", city: city}
end

agent = ADK.new("assistant",
  tools: [&get_weather/1]
)
```

### Declarative Tools

For richer metadata, use the declarative macro:

```elixir
defmodule MyTools.Calculator do
  use ADK.Tool.Declarative

  @tool name: "calculate",
        description: "Evaluate a math expression",
        parameters: %{
          "expression" => %{type: "string", description: "Math expression to evaluate"}
        }
  def run(%{"expression" => expr}, _ctx) do
    {result, _} = Code.eval_string(expr)
    %{result: result}
  end
end
```

## Session Persistence

Sessions can optionally persist to a pluggable store, surviving process restarts:

```elixir
# Start the InMemory store (add to your supervision tree)
ADK.Session.Store.InMemory.start_link([])

# Start a session with persistence
{:ok, pid} = ADK.Session.start_link(
  app_name: "my_app",
  user_id: "user1",
  session_id: "sess1",
  store: {ADK.Session.Store.InMemory, []}
)

# Work with the session normally
ADK.Session.put_state(pid, :counter, 42)

# Explicitly save
ADK.Session.save(pid)

# Or use auto_save: true to save on process termination
```

### Available Stores

| Store | Backend | Best for |
|-------|---------|----------|
| `ADK.Session.Store.InMemory` | ETS table | Testing, single-node |
| `ADK.Session.Store.JsonFile` | JSON files on disk | Development, simple deploys |

### Custom Store

Implement the `ADK.Session.Store` behaviour:

```elixir
defmodule MyApp.RedisStore do
  @behaviour ADK.Session.Store

  @impl true
  def load(app_name, user_id, session_id), do: # ...
  def save(session), do: # ...
  def delete(app_name, user_id, session_id), do: # ...
  def list(app_name, user_id), do: # ...
end
```

## Architecture

```
ADK.Runner
├── ADK.Session (GenServer per session — state, event history)
├── ADK.Context (immutable invocation context, threaded through pipeline)
└── ADK.Agent (behaviour)
    ├── ADK.Agent.LlmAgent (LLM ↔ tool loop)
    └── ADK.Agent.SequentialAgent (pipeline)
```

**Core types:**
- `ADK.Event` — universal event struct (text, tool calls, tool results, errors)
- `ADK.EventActions` — state deltas, agent transfers, escalation
- `ADK.Context` — invocation context with state scopes and branching
- `ADK.Tool` — behaviour for tool implementations

## Design Docs

Detailed design documents covering the architecture decisions:

- [State Management](https://github.com/zeroasterisk/adk-elixir/wiki/State-Design) — GenServer sessions, ETS for shared state, delta tracking
- [Agents & Tools](https://github.com/zeroasterisk/adk-elixir/wiki/Agents-Tools-Design) — OTP supervision, tool behaviours, error recovery
- [Messaging & Streaming](https://github.com/zeroasterisk/adk-elixir/wiki/Messaging-Design) — event flow, Phoenix integration, A2A
- [API Surface](https://github.com/zeroasterisk/adk-elixir/wiki/API-Design) — DX, pipe composition, ExDoc, Mix generators

## Development

```bash
# Get deps
mix deps.get

# Run tests
mix test

# Generate docs
mix docs

# Run with IEx
iex -S mix
```

## Phoenix Integration

ADK works seamlessly with Phoenix — no Phoenix dependency required. We provide optional helpers for three patterns:

- **REST API** — `ADK.Phoenix.Controller` for JSON endpoints and SSE streaming
- **WebSocket** — `ADK.Phoenix.Channel` for real-time bidirectional communication
- **LiveView** — `ADK.Phoenix.LiveHandler` for server-rendered real-time UIs

The foundation is `ADK.Runner.Async`, a pure OTP module that runs agents in background processes:

```elixir
{:ok, _pid} = ADK.Runner.Async.run(runner, user_id, session_id, "Hello!")
# Receive {:adk_event, event} messages in your process
```

📖 **[Full Phoenix Integration Guide](guides/phoenix-integration.md)**

## Roadmap

- [x] LoopAgent, ParallelAgent
- [x] Real LLM backend (Gemini via API)
- [x] Session persistence (InMemory ETS + JsonFile stores)
- [x] Phoenix integration (LiveView, Channels)
- [ ] A2A server/client
- [x] `mix adk.new` generator
- [ ] Publish to Hex

## License

Apache 2.0
