# ADK Elixir — Intentional Differences from Python ADK

This document catalogs the ways ADK Elixir intentionally diverges from the Python ADK
implementation. Each difference was reviewed during design and behavioral parity audits
(2026-03-09, 2026-03-12) and confirmed as either equivalent or superior to the Python approach.

**For unintentional gaps / known missing features, see [`docs/review/`](review/).**

---

## Summary Table

| # | Area | Python ADK | ADK Elixir | Type |
|---|------|-----------|------------|------|
| 1 | [Request assembly](#1-consolidated-request-building-vs-processor-pipeline) | 12-step `BaseLlmRequestProcessor` pipeline | `build_request/2` + `InstructionCompiler` | Simplification |
| 2 | [Callback ordering](#2-callback-vs-plugin-ordering) | Plugins first, then agent callbacks | Agent callbacks first, then plugins | Semantic clarity |
| 3 | [Policy system](#3-policy-system-elixir-only) | Ad-hoc callbacks/plugins | Dedicated `ADK.Policy` behaviour | Elixir-only addition |
| 4 | [Agent abstraction](#4-agent-as-protocol-vs-class-hierarchy) | `BaseAgent` class hierarchy (inheritance) | `ADK.Agent` protocol (structural) | Idiomatic Elixir |
| 5 | [Tool dispatch](#5-tool-dispatch--protocol-based-vs-class-inheritance) | `BaseTool` ABC + class inheritance | `ADK.Tool` behaviour + structs | Idiomatic Elixir |
| 6 | [Tool functions: MFA tuples](#6-mfa-tuples-for-tool-functions) | Lambda/function references | MFA tuples `{Module, :fun, extra_args}` | Compile-time safety |
| 7 | [Session management](#7-genserver-session-vs-state-delta-events) | State delta events, applied by session service | GenServer per session, direct mutation | Idiomatic OTP |
| 8 | [State key lookup](#8-state-key-lookup) | String keys only | String keys with atom fallback | Elixir ergonomics |
| 9 | [Streaming](#9-callback-based-vs-asyncgenerator-streaming) | `AsyncGenerator[Event]` | `on_event` callback + supervised Task | OTP patterns |
| 10 | [Auth flow](#10-inline-auth-vs-auth-processor) | `AuthRequestProcessor` in pipeline | Inline `{:error, {:auth_required, cfg}}` | Simpler control flow |
| 11 | [Auth events](#11-auth-event-filtering) | `adk_request_euc` events in session history | Auth as return values, no events | Cleaner event stream |
| 12 | [Error callbacks](#12-error-callback-chain) | Plugin chain, then agent callbacks | Unified `Callback.run_on_error/3` | Simpler |
| 13 | [Instruction compilation](#13-staticdynamic-instruction-split) | `InstructionRequestProcessor` + `ContextCacheProcessor` | `compile_split/2` returns `{static, dynamic}` | Explicit caching support |
| 14 | [Transfer instructions](#14-transfer-instructions) | Verbose (~20 lines) prompt engineering | Concise (~5 lines) + enum constraint | Token efficiency |
| 15 | [Compaction tracking](#15-message-based-vs-timestamp-based-compaction-tracking) | Timestamp ranges, re-filter events | Message counts, compressed list | Simpler in-memory |
| 16 | [Context compressor strategies](#16-context-compressor-strategies-elixir-only) | Token-budget compaction only | SlidingWindow, Summarize, Truncate, TokenBudget | Elixir-only addition |
| 17 | [OTP supervision](#17-otp-supervision-tree-elixir-only) | No built-in supervision | Full supervision tree with restart strategies | Elixir-only addition |
| 18 | [Circuit breaker](#18-circuit-breaker-elixir-only) | Not built-in | `ADK.LLM.CircuitBreaker` | Elixir-only addition |
| 19 | [Phoenix LiveView UI](#19-phoenix-liveview-native-ui-elixir-only) | Separate frontend (ADK Web) | Native LiveView, channels, SSE | Elixir-only addition |
| 20 | [Oban integration](#20-oban-integration-elixir-only) | No built-in job queue | `ADK.Oban.AgentWorker` | Elixir-only addition |
| 21 | [A2A protocol](#21-a2a-protocol--first-class-vs-separate-package) | Separate `adk-a2a` package | First-class `ADK.A2A` module | Integrated |
| 22 | [HITL confirmation](#22-hitl-confirmation-elixir-only) | Not built-in (pattern, not API) | `ADK.Policy.ConfirmationPolicy` | Elixir-only addition |
| 23 | [Telemetry](#23-telemetry--beam-native-vs-opentelemetry) | OpenTelemetry tracing | `:telemetry` + OTel bridge | Idiomatic BEAM |

---

## Architecture

### 1. Consolidated Request Building vs. Processor Pipeline

**Python**: Uses 12 sequential `BaseLlmRequestProcessor` subclasses, each with a `run_async()` method, executed in a fixed order within `SingleFlow`/`AutoFlow`:
`Basic → Auth → Instructions → Identity → Compaction → Contents → Caching → Planning → CodeExecution → OutputSchema → AgentTransfer → NLPlanning`

**Elixir**: Uses `build_request/2` (a single function) + `InstructionCompiler.compile_split/2` to assemble the same data.

**Rationale**: The processor pipeline is an implementation detail of Python's class-based architecture. Elixir's functional approach achieves the same data assembly in ~100 lines vs ~600 across 12 files. Adding new processing steps means adding lines to `build_request/2`, not creating new classes.

**Code**: [`lib/adk/agent/llm_agent.ex`](../lib/adk/agent/llm_agent.ex), [`lib/adk/instruction_compiler.ex`](../lib/adk/instruction_compiler.ex)

---

### 2. Callback vs. Plugin Ordering

**Python**: Plugins fire FIRST, then per-agent callbacks. A global plugin can short-circuit before the agent's own callbacks run.

**Elixir**: Per-invocation `ADK.Callback` modules fire FIRST (inside agent execution), then global `ADK.Plugin` modules wrap the Runner.

**Rationale**: Per-invocation callbacks should take priority over global plugins. A specific callback saying "skip this model call" should override a general plugin that wants to log it. This ordering is more intuitive for the common case.

**Code**: [`lib/adk/callback.ex`](../lib/adk/callback.ex), [`lib/adk/plugin.ex`](../lib/adk/plugin.ex)

---

### 3. Policy System (Elixir-only)

**Python**: No first-class policy concept. Tool authorization is done via callbacks or manual checks inside tool implementations.

**Elixir**: `ADK.Policy` provides:
- Input filters — reject or transform user input before the agent sees it
- Output filters — redact or transform agent output before the caller receives it
- Per-tool authorization — `:allow` or `{:deny, reason}` per tool invocation
- HITL (human-in-the-loop) approval via `ConfirmationPolicy`

**Rationale**: Safety and authorization deserve a dedicated abstraction, not ad-hoc callbacks. Policies are composable and declarative. The distinction between "what the agent is allowed to do" (policy) and "how the agent reacts to events" (callback) makes both clearer.

**Code**: [`lib/adk/policy.ex`](../lib/adk/policy.ex), [`lib/adk/policy/`](../lib/adk/policy/)

---

### 4. Agent as Protocol vs. Class Hierarchy

**Python**: Uses class inheritance: `BaseAgent → LlmAgent`, `BaseAgent → SequentialAgent`, etc. Pydantic models enforce field schemas. Custom agents subclass `BaseAgent` and override `_run_async_impl()`.

**Elixir**: Uses `defprotocol ADK.Agent` — structural polymorphism. Any struct implementing `ADK.Agent` is an agent. Custom agents implement the protocol for their struct; there's no shared base class.

```elixir
defimpl ADK.Agent, for: MyCustomAgent do
  def name(agent), do: agent.name
  def run(agent, ctx), do: [...]
end
```

**Rationale**: Elixir doesn't have inheritance — protocols are the idiomatic polymorphism mechanism. They are open (third-party libraries can implement an agent protocol for existing structs) and avoid the "fragile base class" problem. Compile-time dispatch is also faster.

**Code**: [`lib/adk/agent.ex`](../lib/adk/agent.ex)

---

### 5. Tool Dispatch — Protocol-based vs. Class Inheritance

**Python**: `BaseTool` is an abstract class. Tools inherit it and override `run_async()`, `_get_declaration()`, etc. FunctionTool wraps callables. The dispatcher uses `isinstance()` checks.

**Elixir**: `ADK.Tool` is a behaviour. Tools are structs that implement the behaviour callbacks: `name/1`, `declaration/1`, `run/2`. Dispatch uses the behaviour protocol, not `isinstance`.

```elixir
defmodule MyTool do
  @behaviour ADK.Tool
  defstruct [:name]
  def name(%{name: n}), do: n
  def declaration(tool), do: %{name: tool.name, ...}
  def run(_tool, ctx, args), do: {:ok, "result"}
end
```

**Rationale**: Behaviours enforce the contract at compile time. Any struct can be a tool without inheriting from a base class. This allows existing Elixir modules to be adapted as tools without modification (via wrapper structs).

**Code**: [`lib/adk/tool.ex`](../lib/adk/tool.ex), [`lib/adk/tool/function_tool.ex`](../lib/adk/tool/function_tool.ex)

---

### 6. MFA Tuples for Tool Functions

**Python**: Tools accept Python callables (lambdas, function references). There is no compile-time verification that the function exists.

**Elixir**: `ADK.Tool.FunctionTool` accepts either an anonymous function OR an MFA tuple `{Module, :function, extra_args}`.

```elixir
# Anonymous function — works but no compile-time check
tool = FunctionTool.new(:greet, fn ctx, args -> {:ok, "hello"} end, ...)

# MFA tuple — compile-time safe, works in Plug.init/1 and hot code reloading
tool = FunctionTool.new(:greet, {MyTools, :greet, []}, ...)
# Called as: MyTools.greet(ctx, args)
```

**Rationale**: MFA tuples are verified at compile time (module + function + arity must exist). They also survive hot code reloading because they resolve to the latest version of the function. Anonymous functions capture a closure snapshot and don't reload.  This matters in production Elixir systems where hot upgrades are common.

**Code**: [`lib/adk/tool/function_tool.ex`](../lib/adk/tool/function_tool.ex)

---

## State Management

### 7. GenServer Session vs. State Delta Events

**Python**: Tools modify state via `tool_context.state["key"] = value`, which creates a `state_delta` in the event's `EventActions`. The session service applies deltas during event processing. State reads go through the service.

**Elixir**: Tools call `ADK.Session.put_state(session_pid, key, value)` directly on the GenServer. The session process owns the state; no delta accumulation needed.

**Rationale**: Direct mutation through GenServer message passing is idiomatic Elixir and provides immediate consistency. The state_delta pattern adds indirection that's unnecessary when you have actor-model concurrency. Concurrent reads are safe because each session is a single process — no race conditions.

**Code**: [`lib/adk/session.ex`](../lib/adk/session.ex), [`lib/adk/tool_context.ex`](../lib/adk/tool_context.ex)

---

### 8. State Key Lookup

**Python**: Uses `state.get(key)` with string keys everywhere.

**Elixir**: Tries string key first, then falls back to `String.to_existing_atom(key)` if not found.

**Rationale**: Elixir maps commonly use atom keys. Supporting both avoids surprising failures when state was set with atoms (common in Elixir) but a template uses string keys (common in Python-style usage). Atoms are interned — `String.to_existing_atom` only succeeds if the atom already exists in the VM, so it's safe against atom table exhaustion.

**Code**: [`lib/adk/state/`](../lib/adk/state/)

---

## Streaming

### 9. Callback-Based vs. AsyncGenerator Streaming

**Python**: Agent execution yields events via `async for event in agent.run_async()`. Events stream out as they're produced. This is fundamental to the Python architecture.

**Elixir**: Events are delivered via the `on_event` callback stored in `ADK.Context`. `Runner.run_async/5` spawns a supervised Task and sends `{:adk_event, event}` messages to the caller. The SSE endpoint in `WebRouter` streams these to clients.

**Rationale**: `AsyncGenerator` is Python-specific. Elixir's OTP patterns (message passing, supervised tasks, GenServer callbacks) are the natural equivalent. The callback model integrates seamlessly with Phoenix Channels and LiveView — consumers just implement an `on_event` handler rather than owning the generator loop. `Runner.run_async/5` also gives the supervisor full fault-isolation over the agent task.

**Code**: [`lib/adk/runner.ex`](../lib/adk/runner.ex), [`lib/adk/runner/async.ex`](../lib/adk/runner/async.ex), [`lib/adk/phoenix/web_router.ex`](../lib/adk/phoenix/web_router.ex)

---

## Auth Flow

### 10. Inline Auth vs. Auth Processor

**Python**: `AuthRequestProcessor` intercepts the request pipeline, checks for pending auth events, and resumes tool execution when credentials arrive. Auth state is managed via special events in the session.

**Elixir**: Auth is handled inline — tools return `{:error, {:auth_required, config}}`, the agent creates an auth event, and the client handles the OAuth flow externally. On the next turn, the credential is present in `ADK.Auth.CredentialStore` and the tool succeeds.

**Rationale**: Simpler control flow. Python's processor approach is necessitated by its pipeline architecture. Elixir can handle it directly because tool execution is a regular function call, not part of a pipeline. The auth handshake is a natural multi-turn conversation — no need for special pipeline interception.

**Code**: [`lib/adk/auth/`](../lib/adk/auth/), [`lib/adk/agent/llm_agent.ex`](../lib/adk/agent/llm_agent.ex)

---

### 11. Auth Event Filtering

**Python**: Creates `adk_request_euc` function call/response events that pollute the session history. A separate `_is_auth_event()` filter strips them before LLM context assembly.

**Elixir**: Auth requirements are return values from tools, not events. The session history stays clean — no filtering needed.

**Rationale**: Framework-internal events in the session history are a form of coupling that leaks implementation details into the data model. Elixir avoids this entirely by keeping auth as control flow, not data.

**Code**: [`lib/adk/auth/`](../lib/adk/auth/)

---

## Error Recovery

### 12. Error Callback Chain

**Python**: `plugin_manager.run_on_model_error_callback()` iterates plugins, then agent-level callbacks check. Return `None` to continue, return a value to substitute.

**Elixir**: `Callback.run_on_error/3` iterates callback modules. First to return `{:retry, ctx}` or `{:fallback, response}` wins. Tagged tuples make intent explicit.

**Rationale**: Same semantics, cleaner API. Returning `None` in Python to mean "pass" is implicit; tagged tuples in Elixir make the caller's intent explicit and eliminate nil-check bugs.

**Code**: [`lib/adk/callback.ex`](../lib/adk/callback.ex)

---

## Instruction Compilation

### 13. Static/Dynamic Instruction Split

**Python**: Instructions are assembled by `InstructionRequestProcessor` and `IdentityRequestProcessor`. Context caching is handled by a separate `ContextCacheProcessor` that guesses which parts are stable.

**Elixir**: `InstructionCompiler.compile_split/2` returns `{static, dynamic}` tuples explicitly. Static parts (global instruction, identity, transfer info) are separated from dynamic parts (agent instruction with state vars, output schema).

**Rationale**: Explicit separation makes it trivial to use with Gemini's context caching API. The caller decides whether to use the split; no heuristic guessing needed. Static content can be cached at the API level for significant latency and cost reduction.

**Code**: [`lib/adk/instruction_compiler.ex`](../lib/adk/instruction_compiler.ex)

---

### 14. Transfer Instructions

**Python**: Verbose transfer instructions (~20 lines) including detailed agent descriptions, role explanations, and parent-transfer notes. Designed for older LLMs that needed extensive prompting.

**Elixir**: Concise transfer instructions (~5 lines) listing agent names and descriptions. The `transfer` tool parameter uses an enum constraint to prevent hallucination.

**Rationale**: Modern LLMs (Gemini 2.0+, Claude 4+) don't need verbose prompting for tool usage. Shorter instructions save tokens and reduce confusion. The enum constraint on the tool parameter is the real guard against hallucinating agent names.

**Code**: [`lib/adk/instruction_compiler.ex`](../lib/adk/instruction_compiler.ex), [`lib/adk/agent/llm_agent.ex`](../lib/adk/agent/llm_agent.ex)

---

## Compaction

### 15. Message-Based vs. Timestamp-Based Compaction Tracking

**Python**: Compaction events store `start_timestamp`/`end_timestamp` ranges. The content processor uses these ranges to filter and exclude raw events when building LLM context.

**Elixir**: Compaction events store message counts. Compressed messages are returned directly from the compressor; no post-hoc range filtering is needed.

**Rationale**: For in-memory sessions, the compressed message list IS the result — no need to store ranges and re-filter on every request. Timestamp ranges become important for persistent sessions with rehydration across processes (documented as a future enhancement for the Ecto store).

**Code**: [`lib/adk/context/compressor.ex`](../lib/adk/context/compressor.ex)

---

### 16. Context Compressor Strategies (Elixir-only)

**Python**: Provides token-budget-aware compaction (`llm_agent.py` uses `_estimate_prompt_token_count` to pre-compact before sending). No pluggable strategy system.

**Elixir**: `ADK.Context.Compressor` is a behaviour with four built-in strategies:

| Strategy | Description |
|---------|-------------|
| `SlidingWindow` | Keep the N most recent messages; discard older ones |
| `Summarize` | Call an LLM to summarize old messages; inject as system message |
| `Truncate` | Hard truncate at N messages with a marker event |
| `TokenBudget` | Estimate token count (chars ÷ 4); fill budget greedily from newest-old messages |

**Rationale**: Different agent use cases have different compaction needs. A customer service bot wants sliding window; a research agent wants summarization. Making the strategy pluggable and providing four built-in options gives developers control without boilerplate.

**Code**: [`lib/adk/context/compressor/`](../lib/adk/context/compressor/)

---

## BEAM Platform Features

These features leverage the OTP/BEAM runtime and have no direct Python equivalent.

### 17. OTP Supervision Tree (Elixir-only)

**Python**: No built-in process supervision. The developer is responsible for restarting crashed agents, managing process lifetimes, and handling concurrency.

**Elixir**: `ADK.Application` starts a full supervision tree on boot:

```
ADK.Application (Application)
├── ADK.RunnerSupervisor (Task.Supervisor)       — supervised agent runs
├── ADK.Auth.InMemoryStore (GenServer)           — credential store
├── ADK.Artifact.InMemory (GenServer)            — artifact store
├── ADK.LLM.CircuitBreaker (GenServer)           — per-model circuit breakers
└── [ADK.Tool.Approval] (GenServer, optional)    — HITL approval server
```

Session processes start under `DynamicSupervisor` with `restart: :temporary` (on-demand, not auto-restarted).

**Rationale**: Production systems need fault tolerance. OTP supervision provides automatic restart, graceful degradation, and process isolation for free. A crashing session doesn't take down the Runner; a crashing LLM backend call doesn't take down other agents.

**Code**: [`lib/adk/application.ex`](../lib/adk/application.ex), [`guides/supervision.md`](../guides/supervision.md)

---

### 18. Circuit Breaker (Elixir-only)

**Python**: No built-in circuit breaker. LLM call failures propagate directly; the developer must implement retry/circuit-breaker logic.

**Elixir**: `ADK.LLM.CircuitBreaker` wraps every LLM backend call with configurable:
- Failure threshold (trips after N consecutive failures)
- Recovery timeout (half-open after M seconds)
- Per-model isolation (Gemini circuit doesn't affect OpenAI)

**Rationale**: LLM APIs experience transient failures, rate limits, and regional outages. A circuit breaker prevents cascade failures where one slow API call blocks all agent runs. BEAM processes make this trivial — the breaker is a GenServer that tracks state per model name.

**Code**: [`lib/adk/llm/circuit_breaker.ex`](../lib/adk/llm/circuit_breaker.ex)

---

### 19. Phoenix LiveView Native UI (Elixir-only)

**Python**: Requires a separate frontend (ADK Web, a separate npm/React project) that communicates with the Python ADK server via REST/WebSocket.

**Elixir**: `ADK.Phoenix` provides native integration:
- `ADK.Phoenix.ChatLive` — full chat UI via Phoenix LiveView (real-time, no JS framework)
- `ADK.Phoenix.Channel` — WebSocket streaming for custom frontends
- `ADK.Phoenix.WebRouter` — Python ADK-compatible HTTP endpoints + SSE streaming
- `ADK.Phoenix.Controller` — REST API for non-LiveView clients

**Rationale**: Phoenix LiveView is Elixir's native real-time UI layer. Shipping a built-in LiveView component eliminates the need for a separate frontend project for most use cases. SSE streaming works out of the box with the same Runner architecture — no bridging required.

**Code**: [`lib/adk/phoenix/`](../lib/adk/phoenix/), [`guides/phoenix-integration.md`](../guides/phoenix-integration.md)

---

### 20. Oban Integration (Elixir-only)

**Python**: No built-in job queue integration. Long-running or scheduled agent tasks require external tooling (Celery, RQ, Cloud Tasks) with significant boilerplate.

**Elixir**: `ADK.Oban.AgentWorker` provides first-class background job processing:

```elixir
# Schedule an agent run as a background job
%{agent: MyAgent, message: "analyze quarterly report", session_id: id}
|> ADK.Oban.AgentWorker.new(schedule_in: 3600)
|> Oban.insert()
```

Features:
- Module-based and inline agent configuration
- Automatic retry with backoff on failures
- Priority queues (`:default`, `:critical`, `:bulk`)
- Scheduling (cron, `schedule_in`)
- Telemetry events for monitoring

**Rationale**: Oban is the de-facto Elixir background job library. Tight integration means agent tasks benefit from Oban's guarantees (at-least-once delivery, observability, queue management) without any glue code.

**Code**: [`lib/adk/oban/agent_worker.ex`](../lib/adk/oban/agent_worker.ex), [`guides/oban-integration.md`](../guides/oban-integration.md)

---

## Protocol & Ecosystem

### 21. A2A Protocol — First-Class vs. Separate Package

**Python**: A2A (Agent-to-Agent) is a separate `adk-a2a` package that must be installed separately. It's not part of the core `google-adk` distribution.

**Elixir**: `ADK.A2A` is a first-class module included in the main package:
- `ADK.A2A.Server` — expose any agent as an A2A-compliant HTTP server
- `ADK.A2A.Client` — call remote A2A agents
- `ADK.A2A.RemoteAgentTool` — use remote agents as tools inside local agents
- `ADK.A2A.AgentCard` — `.well-known/agent.json` discovery

**Rationale**: Agent interoperability should be a first-class concern, not an afterthought. Bundling A2A means any ADK Elixir agent is immediately network-addressable and composable without additional dependencies.

**Code**: [`lib/adk/a2a/`](../lib/adk/a2a/)

---

### 22. HITL Confirmation (Elixir-only)

**Python**: Human-in-the-loop is a pattern described in the docs but not a built-in API. The developer must implement approval flows manually using callbacks.

**Elixir**: `ADK.Policy.ConfirmationPolicy` provides built-in HITL:
- Before sensitive tools execute, the policy calls `ADK.Tool.Approval` (a supervised GenServer)
- The GenServer holds the pending tool call and waits for an external approval signal
- The agent's task blocks (supervised) until approval arrives or times out
- The policy then returns `:allow` or `{:deny, reason}`

**Rationale**: HITL is a critical safety pattern for production agents. Making it a first-class policy rather than a custom callback pattern ensures consistency and reduces boilerplate.

**Code**: [`lib/adk/policy/`](../lib/adk/policy/), [`lib/adk/tool/approval.ex`](../lib/adk/tool/approval.ex)

---

### 23. Telemetry — BEAM-native vs. OpenTelemetry

**Python**: Uses OpenTelemetry directly — `tracer.start_as_current_span()` in agent, model, and tool execution paths.

**Elixir**: Uses `:telemetry` events (BEAM standard), with an optional OpenTelemetry bridge:
- `[:adk, :agent, :start]` / `[:adk, :agent, :stop]`
- `[:adk, :llm, :start]` / `[:adk, :llm, :stop]`
- `[:adk, :tool, :start]` / `[:adk, :tool, :stop]`

**Rationale**: `:telemetry` is the BEAM ecosystem standard — it integrates with Phoenix, Ecto, Broadway, and every major Elixir library. Consumers attach their own handlers; they can route to OpenTelemetry, StatsD, Prometheus, or log aggregators. The ADK doesn't force a telemetry backend.

**Code**: [`lib/adk/telemetry.ex`](../lib/adk/telemetry.ex)

---

## Plugin State Threading

### 24. Explicit Plugin State vs. Mutable Instance State

**Python**: Plugins are class instances. State is stored in instance variables (`self.counter = 0`). The PluginManager holds plugin instances across the run; state is implicitly shared.

**Elixir**: `ADK.Plugin` callbacks thread state explicitly through the invocation:
```elixir
def before_run(ctx, state), do: {:cont, ctx, %{state | count: state.count + 1}}
def after_run(ctx, result, state), do: {:cont, result, state}
```

State is per-invocation, not global. Global state lives in a supervised GenServer.

**Rationale**: Explicit state threading makes data flow visible and eliminates shared mutable state bugs. Each invocation gets a fresh plugin state slice; concurrent invocations can't corrupt each other. For truly global state (e.g., a rate limiter), plugins use a named GenServer — which is visible and explicit.

**Code**: [`lib/adk/plugin.ex`](../lib/adk/plugin.ex), [`lib/adk/plugin/`](../lib/adk/plugin/)

---

*Last updated: 2026-03-13*
*Audits: [behavioral-parity-2026-03-12.md](review/behavioral-parity-2026-03-12.md), [design-review-vs-python.md](design-review-vs-python.md), [python-adk-v1.27.0-comparison-v4.md](review/python-adk-v1.27.0-comparison-v4.md)*
