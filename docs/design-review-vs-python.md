# ADK Elixir vs Python ADK — Design Review

> **Date:** 2026-03-09
> **Reviewer:** Zaf (automated review)
> **Python ADK version:** source from `google/adk-python` (2026 main)
> **Elixir ADK:** current `main` branch

---

## Overview

This document compares architectural decisions in ADK Elixir against the Python ADK reference implementation. Divergences are classified as **Intentional** (idiomatic Elixir choices with clear rationale) or **Unintentional** (gaps/drift that should be addressed for parity).

---

## Summary of Key Design Decisions

| Area | Python ADK | Elixir ADK | Divergence | Classification |
|------|-----------|------------|------------|----------------|
| **Agent abstraction** | Class hierarchy (`BaseAgent` → `LlmAgent`), Pydantic models | Protocol (`ADK.Agent`) + structs | Different polymorphism mechanism | ✅ Intentional |
| **Callbacks — location** | Per-agent fields (`before_agent_callback`, `before_model_callback`, etc.) on agent struct | Separate `ADK.Callback` behaviour, passed via `Runner.run/5` opts | Different ownership model | ⚠️ Unintentional |
| **Callbacks — signature** | Functions receiving `(CallbackContext, ...)`, return `Optional[value]` to short-circuit | Behaviour modules with `before_X/1` returning `{:cont, ctx} \| {:halt, result}` | Tagged tuples vs nil-checking | ✅ Intentional |
| **Callbacks — error hooks** | `on_model_error_callback`, `on_tool_error_callback` on both agent and plugins | `on_model_error/2` on Callback behaviour only; no `on_tool_error` | Missing `on_tool_error` | ⚠️ Unintentional |
| **Plugins — scope** | Class instances with named callbacks, managed by `PluginManager` | Behaviour modules with `before_run/2`, `after_run/3`, managed by `Agent`-based `Registry` | Fewer hook points | ⚠️ Unintentional |
| **Plugin hook points** | 12 hooks: `on_user_message`, `before_run`, `after_run`, `on_event`, `before/after_agent`, `before/after_model`, `on_model_error`, `before/after_tool`, `on_tool_error` | 2 hooks: `before_run`, `after_run` | Missing 10 plugin hooks | ⚠️ Unintentional |
| **Plugin lifecycle** | `close()` method for cleanup, timeout handling | No lifecycle management | Missing cleanup | ⚠️ Unintentional |
| **Plugin + Callback ordering** | Plugins run first, then agent callbacks; plugin can short-circuit both | Plugins wrap Runner; callbacks are inside agent execution — separate layers | Conceptually similar but different granularity | ⚠️ Unintentional |
| **Session management** | Service-based (`BaseSessionService`), external to agent | GenServer per session, supervised via `DynamicSupervisor` | Process-per-session | ✅ Intentional |
| **Session persistence** | Multiple backends: in-memory, SQLite, database, Vertex AI | Store behaviour with InMemory, Ecto, JsonFile | Comparable | ✅ Intentional |
| **Tool registration** | `tools` field accepts callables, `BaseTool`, `BaseToolset`; auto-wraps functions | `tools` field accepts structs (`FunctionTool`, `ModuleTool`); explicit wrapping | No auto-wrapping of bare functions | ⚠️ Unintentional |
| **Tool types** | `BaseTool` ABC, `FunctionTool`, `BaseToolset`, Google Search, etc. | `ADK.Tool` behaviour, `FunctionTool`, `ModuleTool`, `TransferTool`, `DeclarativeTool` | `ModuleTool`/`DeclarativeTool` are Elixir-idiomatic additions | ✅ Intentional |
| **Toolsets** | `BaseToolset` for dynamic tool collections (e.g., MCP) | No toolset abstraction | Missing feature | ⚠️ Unintentional |
| **Policy/Guardrails** | Not a first-class concept in Python ADK (done via callbacks/plugins) | Dedicated `ADK.Policy` behaviour with `authorize_tool`, `filter_input`, `filter_output` | Elixir has MORE here | ✅ Intentional |
| **Telemetry** | OpenTelemetry tracing via `tracer` (spans for agent, model, tool) | `:telemetry` + optional OpenTelemetry bridge | Elixir-idiomatic | ✅ Intentional |
| **Async/streaming** | `AsyncGenerator[Event, None]` — native async streaming | Synchronous list return from `Agent.run/2`; `Runner.Async` for Task-based | No streaming support | ⚠️ Unintentional |
| **Agent tree** | `parent_agent` backlink, `find_agent`, `find_sub_agent`, `root_agent` | `sub_agents` list only, no parent link or tree traversal | Missing tree navigation | ⚠️ Unintentional |
| **Agent cloning** | `clone()` with deep copy of sub-agents | Not implemented | Missing feature | ⚠️ Unintentional |
| **Memory service** | `BaseMemoryService` for long-term memory across sessions | Not implemented | Missing feature | ⚠️ Unintentional |
| **Artifact service** | `BaseArtifactService` for file/blob storage | Not implemented | Missing feature | ⚠️ Unintentional |
| **Credential service** | `BaseCredentialService` for auth management | Not implemented | Missing feature | ⚠️ Unintentional |
| **Live/streaming mode** | `run_live` for audio/video conversations | Not implemented | Missing feature | ⚠️ Unintentional |
| **LLM model inheritance** | Agent inherits model from ancestor if not set | Must be explicitly set per agent | Missing feature | ⚠️ Unintentional |
| **Run config** | `RunConfig` with streaming, speech, custom metadata | `ADK.RunConfig` exists but less feature-complete | Partial | ⚠️ Unintentional |
| **Context cache** | `ContextCacheConfig` for LLM context caching | Not implemented | Missing feature | N/A (low priority) |
| **Phoenix integration** | N/A | Channel, Controller, LiveView, ChatLive | Elixir-only addition | ✅ Intentional |
| **Oban integration** | N/A | `AgentWorker` for background job processing | Elixir-only addition | ✅ Intentional |
| **A2A protocol** | Full A2A implementation | `RemoteAgentTool`, `AgentCard`, `Client`, `Server` | Comparable | ✅ Intentional |
| **MCP support** | Via toolsets | `MCP.Client` + `ToolAdapter` | Comparable | ✅ Intentional |
| **Circuit breaker** | Not built-in | `ADK.LLM.CircuitBreaker` | Elixir-only addition | ✅ Intentional |
| **LLM retry** | Not built-in (plugin/callback) | `ADK.LLM.Retry` | Elixir-only addition | ✅ Intentional |

---

## Detailed Analysis

### 1. Callbacks — Ownership Model (⚠️ Unintentional)

**Python:** Callbacks are per-agent fields. An `LlmAgent` has `before_agent_callback`, `after_agent_callback`, `before_model_callback`, `after_model_callback`, `before_tool_callback`, `after_tool_callback`, plus error variants. They are set on the agent struct and travel with it.

**Elixir:** Callbacks are a separate `ADK.Callback` behaviour passed as a list of modules via `Runner.run/5` options. They apply to the entire invocation, not per-agent.

**Impact:** In Python, different agents in a tree can have different callbacks. In Elixir, all agents in an invocation share the same callback list. This limits composability in multi-agent trees.

**Recommendation:** Add optional `callbacks` field to `LlmAgent` struct. When present, merge with invocation-level callbacks (agent-level takes precedence, matching Python's behavior).

### 2. Plugin Hook Points (⚠️ Unintentional)

**Python:** Plugins have 12 distinct hooks covering the full lifecycle:
- `on_user_message_callback` — before invocation starts
- `before_run_callback` / `after_run_callback` — around the entire run
- `on_event_callback` — after each event is yielded
- `before/after_agent_callback` — around each agent
- `before/after_model_callback` — around each LLM call
- `on_model_error_callback` — on LLM errors
- `before/after_tool_callback` — around each tool call
- `on_tool_error_callback` — on tool errors

**Elixir:** Plugins have only 2 hooks: `before_run` and `after_run`, which wrap the entire Runner execution. All finer-grained interception happens via Callbacks.

**Impact:** There's a conceptual gap. In Python, plugins and callbacks both cover the same hooks (plugins globally, callbacks per-agent). In Elixir, plugins are coarse-grained wrappers and callbacks handle the fine-grained hooks — but they're different behaviours with different APIs. This creates confusion about when to use which.

**Recommendation:** Either:
- (a) Expand `ADK.Plugin` to mirror Python's hook points, OR
- (b) Document the intentional split clearly and ensure Callbacks cover everything plugins would need

Option (b) is more Elixir-idiomatic (callbacks-as-behaviours is clean), but the Plugin behaviour should at minimum add `before/after_agent`, `before/after_model`, `before/after_tool` hooks to match Python's plugin power.

### 3. Missing `on_tool_error` (⚠️ Unintentional)

**Python:** Both callbacks and plugins have `on_tool_error` hooks.

**Elixir:** `ADK.Callback` has `on_model_error` but no `on_tool_error`. Tool errors are caught in `LlmAgent.execute_tools/3` and returned as error maps with no callback interception.

**Recommendation:** Add `on_tool_error/2` to `ADK.Callback` behaviour.

### 4. Streaming / AsyncGenerator (⚠️ Unintentional)

**Python:** `run_async` returns `AsyncGenerator[Event, None]` — events stream out as they're produced. This is fundamental to the architecture.

**Elixir:** `Agent.run/2` returns `[ADK.Event.t()]` — a complete list. No streaming. The `Runner.Async` module wraps execution in a `Task` but still returns a complete list.

**Recommendation:** Consider `Stream` or GenStage-based streaming. At minimum, support a callback/hook that receives events as they're produced (similar to `on_event_callback` in Python plugins).

### 5. Agent Tree Navigation (⚠️ Unintentional)

**Python:** Agents have `parent_agent` backlink, `root_agent` property, `find_agent/find_sub_agent` methods for tree traversal.

**Elixir:** Only `sub_agents` list. No parent link, no tree traversal.

**Recommendation:** Add `parent` field to agent structs and `find_agent/2` helper. The parent link is set in Python's `model_post_init` — equivalent would be a `build/1` function that wires up the tree.

### 6. Tool Auto-wrapping (⚠️ Unintentional)

**Python:** `tools` accepts bare callables — they're auto-wrapped in `FunctionTool`. This is a major DX feature.

**Elixir:** Tools must be explicitly constructed as `FunctionTool` or `ModuleTool` structs.

**Recommendation:** Add a `Tool.wrap/1` function that accepts `fun/1`, `fun/2`, `{module, function}` and auto-wraps. Consider a `tools` macro for DSL sugar.

### 7. Toolsets (⚠️ Unintentional)

**Python:** `BaseToolset` provides dynamic tool collections (tools resolved at runtime, e.g., from MCP servers). `LlmAgent.tools` accepts `ToolUnion = Union[Callable, BaseTool, BaseToolset]`.

**Elixir:** No toolset concept. MCP tools are adapted individually via `MCP.ToolAdapter`.

**Recommendation:** Add `ADK.Toolset` behaviour with `get_tools/1` returning a list of tool structs. Wire into `LlmAgent.effective_tools/1`.

---

## Intentional Divergences — Rationale

### Protocol-based Agent Abstraction
Elixir protocols provide polymorphic dispatch without inheritance. This is idiomatic and allows any struct to implement the Agent protocol without coupling to a base module. **Good choice.**

### GenServer Sessions
Process-per-session is the Elixir way. It provides natural isolation, crash recovery via supervision, and concurrent session handling without locks. **Good choice.**

### `:telemetry` + OTel Bridge
Using the standard `:telemetry` library with optional OpenTelemetry bridging is the established Elixir pattern (used by Phoenix, Ecto, etc.). **Good choice.**

### `ADK.Policy` as First-Class Concept
Python handles guardrails via callbacks/plugins. Elixir's dedicated Policy behaviour with `authorize_tool`, `filter_input`, `filter_output` is cleaner and more explicit. **Good choice — consider proposing upstream to Python ADK.**

### Phoenix/Oban Integration
These are Elixir ecosystem integrations with no Python equivalent. They add significant value for Elixir users. **Good choice.**

### Circuit Breaker / Retry
Built-in resilience patterns that Python leaves to external libraries. Idiomatic in Elixir's "let it crash" + supervision philosophy. **Good choice.**

### `ModuleTool` / `DeclarativeTool`
Module-based tools leverage Elixir's module system naturally. Declarative tools enable config-driven tool definitions. **Good additions.**

---

## Priority Recommendations

### High Priority (Functional Gaps)
1. **Add `on_tool_error` callback** — straightforward addition
2. **Expand plugin hooks** — at least `before/after_agent`, `before/after_model`, `before/after_tool`
3. **Add per-agent callbacks** — `callbacks` field on `LlmAgent` struct
4. **Add tool auto-wrapping** — `Tool.wrap/1` for bare functions

### Medium Priority (Feature Parity)
5. **Streaming events** — Stream-based `run/2` or event callback
6. **Agent tree navigation** — parent links, `find_agent/2`
7. **Toolset abstraction** — `ADK.Toolset` behaviour
8. **Model inheritance** — agents inherit model from parent

### Low Priority (Nice to Have)
9. **Memory service** — cross-session memory
10. **Artifact service** — blob storage
11. **Agent cloning** — deep copy utility
12. **Plugin lifecycle** — `close/1` callback for cleanup

---

## Architecture Diagram (Callback/Plugin Flow)

### Python ADK
```
User Message
  → PluginManager.on_user_message (plugins)
  → PluginManager.before_run (plugins)
  → BaseAgent.run_async
    → PluginManager.before_agent (plugins)
    → agent.before_agent_callback (per-agent)
    → agent._run_async_impl
      → PluginManager.before_model (plugins)
      → agent.before_model_callback (per-agent)
      → LLM call
      → agent.after_model_callback (per-agent)
      → PluginManager.after_model (plugins)
      → PluginManager.before_tool (plugins)
      → agent.before_tool_callback (per-agent)
      → Tool call
      → agent.after_tool_callback (per-agent)
      → PluginManager.after_tool (plugins)
    → agent.after_agent_callback (per-agent)
    → PluginManager.after_agent (plugins)
  → PluginManager.on_event (plugins, per event)
  → PluginManager.after_run (plugins)
```

### Elixir ADK (Current)
```
User Message
  → Plugin.run_before (global plugins — before_run only)
  → Policy.run_input_filters
  → Callback.run_before(:before_agent) (invocation-level)
  → Agent.run
    → Callback.run_before(:before_model) (invocation-level)
    → LLM call
    → Callback.run_after(:after_model) (invocation-level)
    → Policy.check_tool_authorization
    → Callback.run_before(:before_tool) (invocation-level)
    → Tool call
    → Callback.run_after(:after_tool) (invocation-level)
  → Callback.run_after(:after_agent) (invocation-level)
  → Policy.run_output_filters
  → Plugin.run_after (global plugins — after_run only)
```

Note the key difference: Python has plugin hooks at every level; Elixir has plugins only at the outermost layer.

---

*Last updated: 2026-03-09*
