# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-05

### Added

#### Core
- `ADK` facade module with `new/2`, `run/3`, `chat/3`, `sequential/2`
- `ADK.Agent` behaviour for building custom agents
- `ADK.Event` — universal event struct (text, tool calls, tool results, errors)
- `ADK.EventActions` — state deltas, agent transfers, escalation
- `ADK.Context` — immutable invocation context with state scopes
- `ADK.Runner` — orchestration layer
- `ADK.Runner.Async` — background agent execution with message-based results

#### Agents
- `ADK.Agent.LlmAgent` — LLM agent with tool call loop
- `ADK.Agent.SequentialAgent` — sequential pipeline agent
- `ADK.Agent.ParallelAgent` — concurrent agent execution
- `ADK.Agent.LoopAgent` — iterative agent with termination conditions
- `ADK.Agent.Custom` — build-your-own agent behaviour

#### Tools
- `ADK.Tool` behaviour
- `ADK.Tool.FunctionTool` — wrap any function as a tool
- `ADK.Tool.Declarative` — `@tool` macro for declarative tool definitions
- `ADK.Tool.ModuleTool` — module-based tools
- `ADK.Tool.TransferTool` / `ADK.Tool.TransferToAgent` — agent-to-agent transfers
- `ADK.Tool.SearchMemoryTool` — search agent memory

#### LLM Backends
- `ADK.LLM` behaviour
- `ADK.LLM.Mock` — deterministic testing backend
- `ADK.LLM.Gemini` — Google Gemini API
- `ADK.LLM.OpenAI` — OpenAI-compatible API
- `ADK.LLM.Anthropic` — Anthropic Claude API
- `ADK.LLM.Retry` — automatic retry with backoff
- `ADK.LLM.CircuitBreaker` — circuit breaker pattern for LLM calls

#### Sessions & State
- `ADK.Session` — GenServer per session with state tracking
- `ADK.Session.Store` behaviour
- `ADK.Session.Store.InMemory` — ETS-backed store
- `ADK.Session.Store.JsonFile` — file-based persistence
- `ADK.Session.Store.Ecto` — database-backed store
- `ADK.State.Delta` — immutable state diffing

#### Memory
- `ADK.Memory.Store` behaviour
- `ADK.Memory.InMemory` — in-memory vector-less memory store

#### A2A Protocol
- `ADK.A2A.Server` — expose agents as A2A servers (Plug-based)
- `ADK.A2A.Client` — call remote A2A agents
- `ADK.A2A.RemoteAgentTool` — use remote agents as tools
- `ADK.A2A.AgentCard` — agent capability discovery

#### Phoenix Integration
- `ADK.Phoenix.Controller` — REST/SSE endpoints
- `ADK.Phoenix.Channel` — WebSocket real-time communication
- `ADK.Phoenix.LiveHandler` — LiveView event handling
- `ADK.Phoenix.ChatLive` — drop-in chat LiveView component
- `ADK.Phoenix.WebRouter` — preconfigured router

#### Plugins & Policies
- `ADK.Plugin` behaviour with `ADK.Plugin.Registry`
- `ADK.Plugin.ReflectRetry` — automatic retry on reflection
- `ADK.Policy` behaviour with `ADK.Policy.DefaultPolicy`

#### Context Compression
- `ADK.Context.Compressor` behaviour
- Truncate, SlidingWindow, and Summarize strategies

#### Artifacts
- `ADK.Artifact.Store` behaviour
- In-memory and GCS backends

#### MCP
- `ADK.MCP.Client` — Model Context Protocol client
- `ADK.MCP.ToolAdapter` — adapt MCP tools to ADK tools

#### Observability
- `ADK.Telemetry` — `:telemetry` event emissions
- Optional OpenTelemetry integration

#### Mix Tasks
- `mix adk.new` — project generator
- `mix adk.gen.migration` — Ecto migration generator

[0.1.0]: https://github.com/zeroasterisk/adk-elixir/releases/tag/v0.1.0
