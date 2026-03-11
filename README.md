# ADK — Agent Development Kit for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/adk.svg)](https://hex.pm/packages/adk)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/adk)
[![CI](https://github.com/zeroasterisk/adk-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/zeroasterisk/adk-elixir/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/adk.svg)](https://github.com/zeroasterisk/adk-elixir/blob/main/LICENSE)

**OTP-native AI agent framework** inspired by [Google ADK](https://github.com/google/adk-python), built for the BEAM.

## Why Elixir for AI Agents?

Python's ADK is great, but Elixir's runtime was *built* for this:

| Challenge | Python ADK | ADK Elixir |
|-----------|-----------|------------|
| **Concurrent agents** | asyncio, threading | Lightweight processes — millions of agents per node |
| **Crash isolation** | try/except per agent | Process boundaries — one agent crash can't take down others |
| **Recovery** | Manual retry logic | OTP supervisors — automatic restart with backoff strategies |
| **Streaming** | Async generators | Native `Stream` + Phoenix PubSub |
| **State** | Shared dicts, locks | Process isolation — no locks, no mutexes, no race conditions |
| **Distribution** | Custom networking | Built-in clustering — agents span nodes transparently |

## Installation

Add `adk` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:adk, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Create an agent
agent = ADK.new("assistant",
  model: "gemini-2.0-flash",
  instruction: "You are a helpful assistant."
)

# Chat (blocking — returns text)
ADK.chat(agent, "What is Elixir?")
#=> "Elixir is a dynamic, functional language designed for building scalable..."

# Run (returns events for full control)
events = ADK.run(agent, "Tell me about OTP")
```

### Configure an LLM Backend

By default, ADK uses a mock LLM for testing. Configure a real backend:

```elixir
# config/config.exs
config :adk, :llm_backend, ADK.LLM.Gemini
config :adk, :gemini_api_key, System.get_env("GEMINI_API_KEY")
```

Supported backends: `ADK.LLM.Gemini`, `ADK.LLM.OpenAI`, `ADK.LLM.Anthropic`.

## Agents

### LLM Agent

The core agent — sends messages to an LLM, handles tool calls, returns events:

```elixir
agent = ADK.new("researcher",
  model: "gemini-2.0-flash",
  instruction: "You research topics thoroughly.",
  tools: [&MyTools.search/1, &MyTools.summarize/1]
)
```

### Sequential Agent

Chain agents — output of one feeds into the next:

```elixir
pipeline = ADK.sequential([
  ADK.new("researcher", instruction: "Find relevant information."),
  ADK.new("writer", instruction: "Write a clear summary from the research.")
])

ADK.chat(pipeline, "Explain BEAM concurrency")
```

### Parallel & Loop Agents

Run agents concurrently or iteratively:

```elixir
# Run multiple agents at once, merge results
parallel = %ADK.Agent.ParallelAgent{
  name: "multi",
  agents: [researcher, fact_checker, editor]
}

# Loop until a condition is met
loop = %ADK.Agent.LoopAgent{
  name: "refiner",
  agent: editor,
  max_iterations: 3
}
```

## Tools

Any function becomes a tool:

```elixir
def get_weather(%{"city" => city}) do
  %{temp: 72, condition: "sunny", city: city}
end

agent = ADK.new("assistant", tools: [&get_weather/1])
```

For richer metadata, use the declarative macro:

```elixir
defmodule MyTools.Calculator do
  use ADK.Tool.Declarative

  @tool name: "calculate",
        description: "Evaluate a math expression",
        parameters: %{
          "expression" => %{type: "string", description: "Math expression"}
        }
  def run(%{"expression" => expr}, _ctx) do
    {result, _} = Code.eval_string(expr)
    %{result: result}
  end
end
```

## Sessions & Persistence

Sessions are GenServers with pluggable storage:

```elixir
# In-memory (ETS), JSON files, or Ecto (any database)
{:ok, pid} = ADK.Session.start_link(
  app_name: "my_app",
  user_id: "user1",
  session_id: "sess1",
  store: {ADK.Session.Store.InMemory, []}
)
```

| Store | Backend | Best for |
|-------|---------|----------|
| `InMemory` | ETS | Testing, single-node |
| `JsonFile` | JSON files | Development |
| `Ecto` | Any database | Production |

## Phoenix Integration

Optional Phoenix helpers — no Phoenix dependency required:

```elixir
# REST API with SSE streaming
plug ADK.Phoenix.Controller

# WebSocket real-time communication
socket "/agent", ADK.Phoenix.Channel

# Drop-in LiveView chat component
live "/chat", ADK.Phoenix.ChatLive
```

📖 See the [Phoenix Integration Guide](guides/phoenix-integration.md).

## A2A Protocol

Full [A2A protocol](https://a2a-protocol.org/latest/) support for inter-agent communication:

```elixir
# Expose as A2A server
plug ADK.A2A.Server, agent: my_agent, runner: runner

# Call remote agents
{:ok, result} = ADK.A2A.Client.send_task("http://remote:4000", "Research OTP")

# Use remote agents as tools
researcher = ADK.A2A.RemoteAgentTool.new(name: "researcher", url: "http://remote:4000")
```

## Plugins & Policies

Extend agent behavior with plugins and safety policies:

```elixir
# Plugin: automatic retry on LLM reflection
ADK.Plugin.Registry.register(ADK.Plugin.ReflectRetry)

# Policy: control what agents can do
config :adk, :policy, MyApp.SafetyPolicy
```

## Observability

Built-in `:telemetry` events + optional OpenTelemetry:

```elixir
# All agent/tool/LLM calls emit telemetry events
:telemetry.attach("my-handler", [:adk, :agent, :run, :stop], &MyHandler.handle/4, nil)
```

## Mix Tasks

```bash
# Generate a new ADK project
mix adk.new my_agent

# Generate Ecto migrations for session persistence
mix adk.gen.migration
```

## Architecture

```
ADK.Runner
├── ADK.Session (GenServer per session)
├── ADK.Context (immutable invocation context)
└── ADK.Agent (behaviour)
    ├── LlmAgent (LLM ↔ tool loop)
    ├── SequentialAgent (pipeline)
    ├── ParallelAgent (concurrent)
    └── LoopAgent (iterative)
```

## Guides

- [Getting Started](guides/getting-started.md)
- [Core Concepts](guides/concepts.md)
- [Project Generator](guides/mix-adk-new.md)
- [Phoenix Integration](guides/phoenix-integration.md)
- [Supervision Trees](guides/supervision.md)
- [Evaluations](guides/evaluations.md)

## License

Apache-2.0 — see [LICENSE](https://github.com/zeroasterisk/adk-elixir/blob/main/LICENSE).
