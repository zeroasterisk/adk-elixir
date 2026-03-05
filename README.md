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

## Roadmap

- [ ] LoopAgent, ParallelAgent
- [ ] Real LLM backend (Gemini via API)
- [ ] Session persistence (Ecto/PostgreSQL)
- [ ] Phoenix integration (LiveView, Channels)
- [ ] A2A server/client
- [ ] `mix adk.new` generator
- [ ] Publish to Hex

## License

Apache 2.0
