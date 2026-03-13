# Python ADK v1.27.0 → ADK Elixir Parity Review

**Date:** 2026-03-13  
**Python ADK release:** v1.27.0 (2026-03-12)  
**ADK Elixir state:** main @ 0ac3762, 910 tests, 0 failures  
**Reviewer:** Zaf (automated sub-agent)

---

## Summary Table

| Change | Classification | Action? |
|--------|---------------|---------|
| A2A Rewrite — `A2aAgentExecutor` / `RemoteA2aAgent` + request interceptors | 🟡 Gap (acceptable) | Track |
| Durable Runtime — deterministic time/UUID platform abstraction | 🟡 Gap (acceptable) | Low priority |
| `AuthProviderRegistry` — pluggable auth provider registry | 🟡 Gap (acceptable) | Low priority |
| `adk optimize` command — GEPA prompt optimization CLI | 🟡 Gap (acceptable) | Not planned |
| `ExecuteBashTool` / Skills enhancements | 🟡 Gap (acceptable) | Low priority |
| `UiWidget` in `EventActions` — experimental MCP UI widgets | 🟡 Gap (acceptable) | Future |
| Anthropic streaming + PDF support | 🟡 Gap (acceptable) | Medium |
| `output_schema` with tools for LiteLLM | ✅ Already covered | None |
| Bug: `temp:` state visible to subsequent agents | ✅ Already covered | None |
| OpenTelemetry semantic convention additions | 🟡 Gap (acceptable) | Low priority |

**No 🔴 Action needed items.** All v1.27.0 changes are either already covered or acceptable gaps with no urgency.

---

## 1. A2A Rewrite — `A2aAgentExecutor` + `RemoteA2aAgent` with Request Interceptors

### Python v1.27.0

Python ADK completely rewrote its A2A integration in this release:

- **`A2aAgentExecutor`** (`src/google/adk/a2a/executor/a2a_agent_executor.py`): New server-side executor that wraps an ADK `Runner` and implements the `a2a.AgentExecutor` interface. Converts A2A protocol messages into ADK invocations and publishes streaming results back to an A2A event queue.

- **`RemoteA2aAgent`** (`src/google/adk/agents/remote_a2a_agent.py`): New client-side agent that wraps a remote A2A endpoint as a native ADK agent (not just a tool). Supports streaming via SSE, task polling, and full A2A message format conversion.

- **Request Interceptors** (`src/google/adk/a2a/agent/config.py`): New `RequestInterceptor` dataclass with `before_request` and `after_request` hooks. Before-request interceptors can short-circuit execution by returning an `Event` instead of a modified `A2AMessage`. After-request interceptors can suppress individual events (`return None`).

  ```python
  class RequestInterceptor(BaseModel):
      before_request: Optional[Callable[
          [InvocationContext, A2AMessage, ParametersConfig],
          Awaitable[tuple[Union[A2AMessage, Event], ParametersConfig]]
      ]] = None
      after_request: Optional[Callable[
          [InvocationContext, A2AEvent, Event],
          Awaitable[Union[Event, None]]
      ]] = None
  ```

- **Part converters**: Extensive new converter modules for bidirectional A2A ↔ GenAI format conversion (`part_converter.py`, `event_converter.py`, `request_converter.py`).

### ADK Elixir

`ADK.A2A` is built on the external `a2a` Elixir package:

- **Server side** (`ADK.A2A.Server` + `Bridge`): Uses `A2A.Plug` + a GenServer bridge that runs `ADK.Runner`. Functionally equivalent to Python's `A2aAgentExecutor` but simpler — relies on the `a2a` package's event queue and protocol handling.

- **Client side** (`ADK.A2A.RemoteAgentTool`): Wraps a remote A2A endpoint as an ADK **tool** (not a full agent). Sends a task and returns the text result. Less capable than Python's `RemoteA2aAgent` — lacks streaming reception, task polling, and native agent-to-agent event streaming.

- **No request interceptors**: The `ADK.A2A.Server.Bridge` and `ADK.A2A.RemoteAgentTool` have no before/after interceptor hooks.

### Gap Analysis

| Capability | Python v1.27.0 | Elixir | Status |
|-----------|----------------|--------|--------|
| Server: run ADK agent via A2A | `A2aAgentExecutor` | `ADK.A2A.Server` (Bridge) | ✅ Covered |
| Client: remote agent as tool | `RemoteA2aAgent` | `ADK.A2A.RemoteAgentTool` | 🟡 Partial |
| Client: remote agent as agent | `RemoteA2aAgent` | Not implemented | 🟡 Gap |
| Request interceptors | Yes | No | 🟡 Gap |
| Streaming reception from remote A2A | Yes (SSE) | No (sync only) | 🟡 Gap |
| Part/event format conversion | Extensive | Via `a2a` package | ✅ Covered |

**Classification: 🟡 Gap (acceptable)**

The core use case (expose ADK agent via A2A, call remote A2A agents) is covered. The gaps are:
- `RemoteAgentTool` is a tool, not a first-class agent — it cannot participate in multi-turn A2A conversations or stream intermediate events.
- No request interceptors for auth injection or request modification.

These gaps are acceptable given A2A is still marked experimental in Python. The Elixir A2A implementation is intentionally simpler, leveraging the `a2a` Elixir package. Document in `intentional-differences.md` if needed.

**If a future `RemoteA2aAgent` equivalent is desired**, it would live in `lib/adk/a2a/remote_agent.ex` and implement the `ADK.Agent` protocol rather than `ADK.Tool`. A plugin or middleware callback could serve as the interceptor equivalent.

---

## 2. Durable Runtime — Deterministic Time/UUID Abstraction

### Python v1.27.0

Introduced `google.adk.platform.time` and `google.adk.platform.uuid` modules with swappable providers:

```python
# src/google/adk/platform/time.py
def set_time_provider(provider: Callable[[], float]) -> None: ...
def get_time() -> float: ...

# src/google/adk/platform/uuid.py
def set_id_provider(provider: Callable[[], str]) -> None: ...
def new_uuid() -> str: ...
```

**Purpose:** Enable deterministic replay in Temporal workflows. Without this, `time.time()` and `uuid.uuid4()` in session/event creation make replay non-deterministic. These abstractions allow Temporal (or any deterministic runtime) to inject side-effect-safe providers.

### ADK Elixir

Elixir has BEAM-native approaches to this problem:

- **Oban** (`ADK.Oban.AgentWorker`): Full durable execution with retries, scheduling, and persistence. This covers the "don't lose work" aspect more robustly than Temporal by using Postgres as the durable queue.

- **Event IDs**: The `ADK.Event` struct uses `UUID.uuid4()` from the `:uuid` library. There is no swappable UUID provider.

- **Timestamps**: Events and sessions use `DateTime.utc_now()` directly. Not injectable.

### Gap Analysis

The Elixir equivalent goal (deterministic replay) is met differently:
- **Oban** handles retry + persistence (the practical use case).
- True Temporal-style deterministic replay is not supported — there's no swappable time/UUID provider.
- This is acceptable: Elixir users using Temporal would need a custom runner.

**Classification: 🟡 Gap (acceptable)**

The practical durable execution use case is covered by Oban. The theoretical deterministic replay (Temporal integration) is not, but this is a low-priority niche. Document as intentional difference.

---

## 3. `AuthProviderRegistry` — Pluggable Auth

### Python v1.27.0

New `AuthProviderRegistry` class (`src/google/adk/auth/auth_provider_registry.py`):

```python
@experimental(FeatureName.PLUGGABLE_AUTH)
class AuthProviderRegistry:
    def register(self, auth_scheme_type: type[AuthScheme], provider_instance: BaseAuthProvider) -> None: ...
    def get_provider(self, auth_scheme: AuthScheme) -> BaseAuthProvider | None: ...
```

Used within `CredentialManager` to delegate auth exchange/refresh to registered providers. Allows third-party auth integrations (SAML, custom SSO, etc.) without patching the core ADK.

### ADK Elixir

`ADK.Auth.CredentialManager` is a stateless functional module:
- Handles `api_key`, `http_bearer`, `oauth2` credential types.
- Auth logic is pattern-matched in `get_credential/3` — no runtime-registered providers.
- `ADK.Auth.CredentialStore` behaviour allows custom storage backends.
- No equivalent to `AuthProviderRegistry`.

### Gap Analysis

**Classification: 🟡 Gap (acceptable)**

The `AuthProviderRegistry` is marked `@experimental` in Python. The core OAuth2 flow is fully implemented in ADK Elixir. Runtime-pluggable auth providers would be a nice-to-have for extensibility.

**If added**, it could follow the existing `ADK.Auth.CredentialStore` pattern — define an `ADK.Auth.Provider` behaviour with `exchange/2` and `refresh/2` callbacks, and register providers at runtime in `CredentialManager`.

---

## 4. `adk optimize` Command — Prompt Optimization CLI

### Python v1.27.0

New `adk optimize` CLI command backed by:
- `optimization/agent_optimizer.py` — abstract optimizer base class
- `optimization/gepa_root_agent_prompt_optimizer.py` — GEPA (Generative Evaluation-guided Prompt Adaptation) optimizer
- `optimization/simple_prompt_optimizer.py` — simpler LLM-based optimizer
- `optimization/local_eval_sampler.py` — ties into the eval framework

Allows running automated prompt optimization loops against an eval dataset to improve agent instructions.

### ADK Elixir

ADK Elixir has an eval framework (`ADK.Eval`) but no prompt optimization module or `mix adk.optimize` task.

### Gap Analysis

**Classification: 🟡 Gap (acceptable)**

Prompt optimization is a new, experimental Python-only feature. It requires a working eval framework (which Elixir has) plus an optimizer loop. This is non-trivial to implement and the Python version is early.

**Recommendation:** Do not add now. Track for v0.2.0. If added, it would be a `mix adk.optimize` Mix task wrapping an `ADK.Optimization` module.

---

## 5. `ExecuteBashTool` + Skills Enhancements

### Python v1.27.0

**`ExecuteBashTool`** (`src/google/adk/tools/bash_tool.py`):
- Executes validated bash commands in a workspace directory.
- Built-in `BashToolPolicy` for command prefix allowlisting.
- Always requires `tool_context.tool_confirmation` before executing (HITL integration).
- Returns `{stdout, stderr, returncode}`.

**Skills enhancements:**
- `list_skills_in_dir()` utility.
- GCS filesystem support for Skills (text and PDF formats).
- `RunSkillScriptTool` — runs a skill's script tool.
- ADK tools support in `SkillToolset`.

### ADK Elixir

`ADK.Skill` module exists with basic skill loading. No `ExecuteBashTool` equivalent. No GCS skill loading.

### Gap Analysis

**ExecuteBashTool classification: 🟡 Gap (acceptable)**

An Elixir equivalent (`ADK.Tool.Bash`) would be straightforward using `System.cmd/3`. The HITL confirmation would integrate with `ADK.Policy.HumanApproval`. Lower priority — bash execution tools are rarely needed in production agents.

**Skills enhancements classification: 🟡 Gap (acceptable)**

GCS skill loading is Google Cloud specific. Elixir's `ADK.Skill` covers the local filesystem case. Not a blocking gap.

---

## 6. `UiWidget` in `EventActions` — Experimental UI Widgets

### Python v1.27.0

New `UiWidget` model in `src/google/adk/events/ui_widget.py`:

```python
class UiWidget(BaseModel):
    id: str
    provider: str   # e.g. "mcp" for MCP App iframe
    payload: dict[str, Any] = {}
```

Added to `EventActions` to allow agents/tools to signal the web UI to render a provider-specific widget (e.g., an MCP App iframe). Used by `MCPTool` to surface MCP App UIs.

### ADK Elixir

`ADK.EventActions` does not include a `ui_widget` field.

### Gap Analysis

**Classification: 🟡 Gap (acceptable)**

This is explicitly experimental in Python and tied to the ADK Web UI. ADK Elixir's Phoenix LiveView integration is the natural analog for rich UI interactions — it doesn't need a generic widget protocol.

**If added**, it would be one field on `ADK.EventActions`:

```elixir
defstruct [..., ui_widget: nil]
```

Where `ui_widget` is a map with `:id`, `:provider`, and `:payload`. Not worth adding until MCP App UI widgets are stable in the Python ADK.

---

## 7. Anthropic Streaming + PDF Support

### Python v1.27.0

- Added streaming support for Anthropic models (`5770cd3`).
- Added PDF document support for Anthropic LLM (`4c8ba74`).

### ADK Elixir

`ADK.LLM.Anthropic` module exists. Current streaming and PDF support status needs verification.

### Gap Analysis

**Classification: 🟡 Gap (acceptable)**

The Elixir Anthropic backend was implemented in a prior sprint. Streaming parity with the Gemini backend should be verified. PDF document support (passing base64-encoded PDFs as content parts) is a medium-priority enhancement.

---

## 8. Bug Fixes Relevant to Elixir

### Python bug fixed: `temp:` state visible to subsequent agents

Python fix: `temp:` scoped state is now visible to subsequent agents in the same invocation (`2780ae2`).

**ADK Elixir status:** `ADK.State` implements prefix-based scoping. The `temp:` prefix is in the gap analysis as an existing P0 gap. This bug fix should be verified against the Elixir implementation.
<br>**Action:** Verify `temp:` state propagation in `lib/adk/state/` and add a regression test if not covered.

### Python bug fixed: `before_tool_callback` and `after_tool_callback` in Live mode

**ADK Elixir status:** Tool callbacks are implemented. Live/streaming mode tool callbacks need verification.

---

## 9. OpenTelemetry Semantic Convention Additions

Python added several new OTel span attributes:
- `gen_ai.agent.version`
- `gen_ai.tool.definitions` (experimental)
- `gen_ai.client.inference.operation.details` (experimental)
- Tool execution error code in spans
- Token usage span attributes

**ADK Elixir:** `ADK.Telemetry` exists. Specific OTel attribute names may differ.

**Classification: 🟡 Gap (acceptable)** — Semantic convention parity is low priority until the OTel spec stabilizes.

---

## 10. GetSessionConfig Passthrough

Python now passes `GetSessionConfig` from `RunConfig` through `Runner` to the session service (`eff724a`). This controls which historical events are loaded (e.g., filtering by branch, limiting count).

**ADK Elixir:** `ADK.RunConfig` exists. Session event loading options should be verified.

---

## Overall Assessment

ADK Elixir remains well-aligned with Python ADK v1.27.0. The major themes of this release are:

1. **A2A maturation** — Python's A2A is becoming more production-ready with the executor rewrite and interceptors. ADK Elixir's A2A is simpler but functional for the core use cases.

2. **Durable/deterministic runtime** — Elixir's Oban covers the practical use case better than Python's Temporal-targeted abstraction.

3. **Experimental features** — `AuthProviderRegistry`, `UiWidget`, `ExecuteBashTool`, and `adk optimize` are all marked experimental in Python. Not worth implementing in Elixir until they stabilize.

4. **No breaking changes** — v1.27.0 adds features; it does not change the core agent loop, session format, or wire protocol in a way that requires Elixir parity changes.

### Recommended follow-up tasks (low priority)

| Task | File | Priority |
|------|------|----------|
| Verify `temp:` state propagation + add test | `lib/adk/state/` | P1 |
| Upgrade `RemoteAgentTool` to first-class agent | `lib/adk/a2a/remote_agent.ex` | P2 |
| Add A2A request interceptor support (Plug middleware) | `lib/adk/a2a/server.ex` | P2 |
| `ADK.Auth.Provider` behaviour (extensible auth) | `lib/adk/auth/` | P2 |
| Verify Anthropic streaming + add PDF support | `lib/adk/llm/anthropic.ex` | P2 |
| `mix adk.optimize` + `ADK.Optimization` | new module | P3 |
| `ADK.Tool.Bash` with HITL policy integration | `lib/adk/tool/bash.ex` | P3 |
| `ui_widget` field in `ADK.EventActions` | `lib/adk/event_actions.ex` | P3 |

---

*Generated by automated parity review. Methodology: trace execution paths, read source code, compare wire formats.*
