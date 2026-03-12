# ADK Elixir — Intentional Differences from Python ADK

This document catalogs the ways ADK Elixir intentionally diverges from the Python ADK
implementation. Each difference was reviewed during the behavioral parity audit
(2026-03-12) and confirmed as either equivalent or superior to the Python approach.

---

## Architecture

### 1. Consolidated Request Building vs. Processor Pipeline

**Python**: Uses 12 sequential `BaseLlmRequestProcessor` subclasses, each with a `run_async()` method, executed in a fixed order within `SingleFlow`/`AutoFlow`.

**Elixir**: Uses `build_request/2` (a single function) + `InstructionCompiler.compile_split/2` to assemble the same data.

**Rationale**: The processor pipeline is an implementation detail of Python's class-based architecture. Elixir's functional approach achieves the same data assembly in ~100 lines vs ~600 across 12 files. Adding new processing steps means adding lines to `build_request/2`, not creating new classes.

### 2. Callbacks vs. Plugins Separation

**Python**: Has `canonical_before_model_callbacks` (agent-level) and `plugin_manager` callbacks (global). Plugins fire FIRST, then agent callbacks.

**Elixir**: Has `ADK.Callback` (per-invocation) and `ADK.Plugin` (global). Callbacks fire FIRST, then plugins.

**Rationale**: Per-invocation callbacks should take priority over global plugins. A specific callback saying "skip this model call" should override a general plugin that wants to log it. This ordering is more intuitive.

### 3. Policy System (Elixir-only)

**Python**: No first-class policy concept. Tool authorization is done via callbacks.

**Elixir**: `ADK.Policy` provides:
- Input filters (reject/transform user input)
- Output filters (redact/transform agent output)
- Per-tool authorization (`:allow` / `{:deny, reason}`)
- HITL (human-in-the-loop) approval via `ConfirmationPolicy`

**Rationale**: Safety and authorization deserve a dedicated abstraction, not ad-hoc callbacks. Policies are composable and declarative.

---

## State Management

### 4. GenServer Session vs. State Delta Events

**Python**: Tools modify state via `tool_context.state["key"] = value`, which creates a state_delta in the event's actions. The session service applies deltas during event processing.

**Elixir**: Tools call `ADK.Session.put_state(session_pid, key, value)` directly on the GenServer.

**Rationale**: Direct mutation through GenServer message passing is idiomatic Elixir and provides immediate consistency. The state_delta pattern adds indirection that's unnecessary when you have actor-model concurrency.

### 5. State Key Lookup

**Python**: Uses `state.get(key)` with string keys.

**Elixir**: Tries string key first, then falls back to `String.to_existing_atom(key)`.

**Rationale**: Elixir maps commonly use atom keys. Supporting both avoids surprising failures when state was set with atoms (common in Elixir) but the template uses strings.

---

## Streaming

### 6. Callback-Based vs. AsyncGenerator Streaming

**Python**: Agent execution yields events via `async for event in agent.run_async()`.

**Elixir**: Events are delivered via `on_event` callback stored in Context. `Runner.run_async/5` spawns a supervised Task and sends `{:adk_event, event}` messages.

**Rationale**: AsyncGenerators are Python-specific. Elixir's OTP patterns (message passing, supervised tasks, GenServer callbacks) are the natural equivalent. The callback model integrates seamlessly with Phoenix Channels and LiveView.

---

## Auth Flow

### 7. Inline Auth vs. Auth Processor

**Python**: `AuthRequestProcessor` intercepts the request pipeline, checks for pending auth events, and resumes tool execution when credentials arrive.

**Elixir**: Auth is handled inline — tools return `{:error, {:auth_required, config}}`, the agent creates an auth event, and the client handles the OAuth flow. Next turn, the credential is present.

**Rationale**: Simpler control flow. Python's processor approach is necessitated by its pipeline architecture. Elixir can handle it directly because tool execution is a regular function call, not part of a pipeline.

### 8. Auth Event Filtering

**Python**: Creates `adk_request_euc` function call/response events that are filtered from LLM context by `_is_auth_event()`.

**Elixir**: Auth requirements are return values, not events. No filtering needed.

**Rationale**: Cleaner event stream. Framework-internal events in the session history are a form of coupling that Elixir avoids.

---

## Error Recovery

### 9. Error Callback Chain

**Python**: `plugin_manager.run_on_model_error_callback()` iterates plugins, then agent-level callbacks check.

**Elixir**: `Callback.run_on_error/3` iterates callback modules. First to return `{:retry, ctx}` or `{:fallback, response}` wins.

**Rationale**: Same semantics, different organization. Elixir's unified callback chain is simpler to reason about.

---

## Instruction Compilation

### 10. Static/Dynamic Instruction Split

**Python**: Instructions are assembled by `InstructionRequestProcessor` and `IdentityRequestProcessor`. Context caching is handled by `ContextCacheProcessor` looking at instruction stability.

**Elixir**: `InstructionCompiler.compile_split/2` returns `{static, dynamic}` tuples explicitly. Static parts (global instruction, identity, transfer info) are separated from dynamic parts (agent instruction with state vars, output schema).

**Rationale**: Explicit separation makes it trivial to use with Gemini's context caching API. The caller decides whether to use the split; no separate processor needed.

### 11. Transfer Instructions

**Python**: Verbose transfer instructions (~20 lines) including detailed agent descriptions, role explanations, and parent-transfer notes.

**Elixir**: Concise transfer instructions (~5 lines) listing agent names and descriptions.

**Rationale**: Modern LLMs (Gemini 2.0+, Claude 4+) don't need verbose prompting for tool usage. Shorter instructions save tokens and reduce confusion. The enum constraint on the tool parameter is the real guard against hallucination.

---

## Compaction

### 12. Message-Based vs. Timestamp-Based Compaction Tracking

**Python**: Compaction events store `start_timestamp`/`end_timestamp` ranges. Content processor uses ranges to filter raw events.

**Elixir**: Compaction events store message counts. Compressed messages are returned directly from the compressor; no post-hoc range filtering needed.

**Rationale**: For in-memory sessions, the compressed message list IS the result — no need to store ranges and re-filter. Timestamp ranges become important for persistent sessions with rehydration, which is documented as a future enhancement.

---

## Elixir-Only Features

These features have no Python equivalent and represent advantages of the BEAM platform:

| Feature | Description |
|---------|-------------|
| **OTP Supervision** | Agent processes supervised by OTP supervisors with restart strategies |
| **Circuit Breaker** | Per-model circuit breaker prevents cascade failures |
| **LLM Retry** | Automatic exponential backoff retry on transient LLM errors |
| **Phoenix LiveView** | Real-time UI without JavaScript via LiveView integration |
| **Oban Integration** | Background job processing for long-running agent tasks |
| **Policy System** | Declarative input/output/tool authorization policies |
| **HITL Confirmation** | Built-in human-in-the-loop approval via ConfirmationPolicy |
| **Telemetry** | BEAM telemetry integration for metrics and tracing |

---

*Last updated: 2026-03-12 by behavioral parity audit*
