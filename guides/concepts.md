# Concepts

## Architecture

ADK Elixir follows a layered architecture where each layer has a clear responsibility:

```
┌──────────────────────────────────┐
│  ADK (facade)                    │  ← Simple API: new/run/chat
├──────────────────────────────────┤
│  Runner                          │  ← Orchestration: session + context + agent
├──────────────────────────────────┤
│  Agents                          │  ← LlmAgent, SequentialAgent, ...
├──────────────────────────────────┤
│  Tools / LLM / Session           │  ← Infrastructure
└──────────────────────────────────┘
```

## Agents as Processes

The key insight of ADK Elixir: **agents map naturally to OTP processes.**

In Python/Go, agents are objects that get called. In Elixir, agents _run_ — they're processes with lifecycles, supervision, and crash isolation. This means:

- A failing tool can't crash your agent (process isolation)
- A supervisor can restart a crashed agent automatically
- Parallel agents use real concurrency (goroutine-like, but with mailboxes)

## Events

Everything in ADK flows through **events**. An event represents something that happened:

- User sent a message → `%Event{author: "user"}`
- Agent responded → `%Event{author: "assistant"}`
- Tool was called → `%Event{actions: %{tool_calls: [...]}}`
- Tool returned → `%Event{author: "tool"}`
- State changed → `%Event{actions: %{state_delta: %{...}}}`

Events are immutable structs. They flow through the system as streams.

## State Scopes

ADK manages state at four scopes:

| Scope | Lifetime | Storage | Use Case |
|-------|----------|---------|----------|
| **App** | Global | ETS | Config, shared knowledge |
| **User** | Per-user | ETS | User preferences, history |
| **Session** | Per-conversation | GenServer | Conversation context |
| **Temp** | Per-invocation | Context struct | Scratch data |

Session state is the most common. It lives in the Session GenServer and persists across turns within a conversation.

## Context

`ADK.Context` is an immutable struct threaded through every function call. It carries:

- Current state (all scopes)
- Session reference
- Agent metadata
- Invocation ID

It's passed explicitly — no global state, no process dictionary magic.

## Tools

A tool is anything that implements the `ADK.Tool` behaviour:

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()
@callback run(args :: map(), context :: ADK.ToolContext.t()) :: any()
```

The simplest tool is a function — `ADK.Tool.FunctionTool` wraps any function automatically with name and parameter inference.

## Sessions

Each conversation gets a `ADK.Session` GenServer. It:

- Stores conversation state (key-value map)
- Tracks event history
- Applies state deltas from events
- Provides isolation (process boundary = state boundary)

Sessions are created by the Runner and can be persisted to external storage.
