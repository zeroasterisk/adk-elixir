# ADK Elixir vs Python ADK — Gap Analysis
**Date:** 2026-03-11  
**Python ADK version:** v1.26.0 (released 2026-02-26)  
**Elixir ADK version:** 0.1.0  
**Author:** Zaf (automated nightly review)

---

## Executive Summary

ADK Elixir covers the core agent loop well — LlmAgent, multi-agent patterns, tools, LLM backends, auth, MCP, A2A, and Phoenix integration are all solid. The framework has meaningful BEAM-native advantages (OTP supervision, Oban, CircuitBreaker, real parallelism). However, several high-value Python features are absent or incomplete: token budget management, Agent Skills, a distributed Agent Registry, planners, HITL, streaming to consumers, and Vertex AI Memory Bank.

---

## Feature Coverage Matrix

| Feature | Python ADK | Elixir ADK | Gap Level |
|---------|-----------|-----------|-----------|
| LlmAgent + tool call loop | ✅ | ✅ | None |
| SequentialAgent | ✅ | ✅ | None |
| ParallelAgent | ✅ | ✅ (OTP Tasks, better) | None |
| LoopAgent | ✅ | ✅ | None |
| Custom agents | ✅ | ✅ | None |
| FunctionTool / @tool macro | ✅ | ✅ | None |
| LongRunningTool | ✅ | ✅ (supervised BEAM Task) | None |
| TransferTool / agent handoff | ✅ | ✅ | None |
| MCP client | ✅ | ✅ | None |
| Gemini / OpenAI / Anthropic backends | ✅ | ✅ | None |
| LiteLLM backend | ✅ | ❌ | Low |
| Apigee LLM | ✅ | ❌ | Skip (GCP-specific) |
| Retry + CircuitBreaker | ✅ | ✅ (Elixir is better) | None |
| Auth / OAuth2 / ServiceAccount | ✅ | ✅ | None |
| ID token support in OAuth2 | ✅ (v1.26) | ❓ (check) | Possible |
| In-memory session store | ✅ | ✅ | None |
| File-based session store | ✅ | ✅ | None |
| DB session store (Ecto) | ✅ | ✅ | None |
| Artifacts (InMemory + GCS) | ✅ | ✅ | None |
| Memory / SearchMemoryTool | ✅ | ✅ | None |
| **Vertex AI Memory Bank** | ✅ | ❌ | Medium |
| **Memory consolidation** | ✅ (v1.25) | ❌ | Medium |
| **Token compaction** | ✅ (v1.25-26) | ❌ | High |
| Context compression (message-count) | ❌ | ✅ | Elixir-ahead |
| Callbacks (before/after agent/model/tool) | ✅ | ✅ | None |
| Eval framework | ✅ | ✅ | Minor |
| **User Personas in Eval** | ✅ (v1.26) | ❌ | Low |
| **Agent Skills** (load_skill_from_dir) | ✅ (v1.26) | ❌ | High |
| **Agent Registry** | ✅ (v1.26) | ❌ | Medium |
| **Planners** (ReAct, Plan-then-Execute) | ✅ | ❌ | Medium |
| **Human-in-the-Loop (HITL)** | ✅ | ❌ | Medium |
| **Streaming tokens to consumer** | ✅ | Partial (Phoenix only) | Medium |
| **A2A interceptors** | ✅ (v1.26) | ❌ | Low |
| Built-in code execution tool | ✅ | Example only | Low |
| BigQuery integration | ✅ | ❌ | Skip |
| OTP supervision trees | ❌ | ✅ | Elixir-ahead |
| Oban job queue integration | ❌ | ✅ | Elixir-ahead |
| Phoenix LiveView UI | ❌ | ✅ | Elixir-ahead |
| Mix adk.server dev server | ❌ | ✅ | Elixir-ahead |
| Plugins (cache, rate-limit, logging) | ❌ | ✅ | Elixir-ahead |

---

## Gaps by Priority

### 🔴 High Priority

#### 1. Token Compaction
**Python:** v1.25-1.26 added intra-invocation compaction and pre-request token-budget compaction. The LLM call is compacted before it would exceed context limits, preserving recent turns and summarizing older ones.  
**Elixir:** Has `ADK.Context.Compressor` but it's message-count based (`threshold: 50`). No token counting, no budget-aware compaction, no per-model context window knowledge.  
**Fix:** Add `ADK.Context.Compressor.TokenBudget` strategy. Wire in model context window configs. Track token usage from LLM responses and trigger compaction proactively.

#### 2. Agent Skills
**Python:** `load_skill_from_dir()` loads tools from a directory following the AgentSkills spec (validation, aliases, scripts, auto-injection into agent). Skills are shareable, versioned packages of tools.  
**Elixir:** No equivalent. Tools are always defined in code.  
**Fix:** Design `ADK.Skill` — a behaviour/struct that wraps a set of tools with metadata. Add `ADK.Skill.load_from_dir/1` that reads a skill manifest (e.g., `skill.json` or `skill.exs`). Auto-inject into `LlmAgent` system instruction.

---

### 🟡 Medium Priority

#### 3. Vertex AI Memory Bank
**Python:** `VertexAiMemoryBankService` with consolidation, generate/create write modes. Persistent cross-session memory backed by Vertex AI.  
**Elixir:** Only `ADK.Memory.InMemory`. No persistent or cloud-backed memory store.  
**Fix:** Add `ADK.Memory.Store.VertexAI` implementing the `ADK.Memory.Store` behaviour using Vertex AI Memory Bank API via `Req`.

#### 4. Planners
**Python:** `PlanReActPlanner` and `Plan-then-Execute` paradigm. Agent generates a plan before taking action steps.  
**Elixir:** `LoopAgent` can approximate this but there's no explicit planning abstraction.  
**Fix:** Add `ADK.Agent.PlannerAgent` (or a planner plugin for `LlmAgent`) that forces a "plan" turn before action turns. Wire into `RunConfig`.

#### 5. Human-in-the-Loop (HITL)
**Python:** Agent can pause and emit an approval request event. Caller resumes with an approval decision. Used for sensitive actions.  
**Elixir:** Nothing in the framework. Partially possible manually but no structured pattern.  
**Fix:** Add `ADK.Event.type = :approval_request | :approval_response`. Add `ADK.Tool.HumanApprovalTool`. The runner should pause a session pending approval and resume on response. Fits naturally with BEAM process model (GenServer await).

#### 6. Agent Registry
**Python:** Centralized registry for agent discovery. Creates AgentCards for registered agents, enables multi-agent routing.  
**Elixir:** Has `ADK.Plugin.Registry` for plugins but no agent discovery registry. A2A `AgentCard` struct exists.  
**Fix:** Add `ADK.Agent.Registry` as a GenServer that tracks running agent instances and their capabilities. Expose via A2A server's agents endpoint.

#### 7. First-class Streaming to Consumer
**Python:** `run_async` with streaming yields events as they arrive from the LLM.  
**Elixir:** Phoenix LiveView streams work. But `ADK.run/3` returns a list (blocking). No `run_stream/3` that returns a stream/enumerable of events as tokens arrive.  
**Fix:** Add `ADK.Runner.stream/5` that returns a `Stream` backed by a GenServer receiving LLM chunks. Or use `Task.async_stream` + agent message passing. Expose on the `ADK` facade.

---

### 🟢 Low Priority

#### 8. A2A Interceptor Framework
**Python:** v1.26 added `A2aAgentExecutor` interceptors — middleware-style pre/post hooks on A2A calls.  
**Elixir:** No equivalent. Callbacks cover agent/model/tool, but not the A2A boundary specifically.  
**Fix:** Add `ADK.A2A.Interceptor` behaviour (similar to existing `ADK.Callback`) wired into `ADK.A2A.Server`.

#### 9. LiteLLM Backend
**Python:** `LiteLlm` covers 100+ model providers.  
**Elixir:** Only Gemini/OpenAI/Anthropic. OpenAI-compatible covers many providers but not all.  
**Fix:** Add `ADK.LLM.Lite` that shells out to LiteLLM via HTTP proxy (user runs LiteLLM proxy server). Low-effort wrapper.

#### 10. User Personas in Eval
**Python:** Inject user personas into eval runs for more realistic test scenarios.  
**Elixir:** Eval framework is solid but no persona system.  
**Fix:** Add `ADK.Eval.Persona` struct. Wire into `ADK.Eval.Case` as optional `user_persona` field. Apply persona instructions to the mock LLM response shaping.

#### 11. Built-in Code Execution Tool
**Python:** `BuiltInCodeExecution` wraps Gemini's server-side code execution.  
**Elixir:** Has an `examples/code_execution_agent` but no packaged tool.  
**Fix:** Add `ADK.Tool.CodeExecution` that proxies to Gemini's built-in code execution feature. Low effort since `ADK.LLM.Gemini` already handles model config.

---

## Elixir-Ahead Features (Things Python ADK Lacks)

These are BEAM/Elixir-native advantages worth documenting and highlighting:

| Feature | Why it's better |
|---------|----------------|
| **OTP supervision trees** | Agents supervised by OTP — crash recovery, health, restart strategies |
| **CircuitBreaker pattern** | LLM call circuit breaker prevents cascade failures |
| **Oban integration** | Persistent background job queue for agent tasks |
| **Phoenix LiveView UI** | Real-time streaming chat UI built into the framework |
| **mix adk.server** | One-command dev server with hot reload |
| **Plugin system** | Cache, rate-limit, logging as composable middleware |
| **Parallel execution** | `ParallelAgent` uses real OS threads, not asyncio concurrency |

---

## Recommended Work Queue

| Task | Priority | Est. Effort |
|------|----------|-------------|
| Token budget compaction (`ADK.Context.Compressor.TokenBudget`) | High | 2 days |
| Agent Skills (`ADK.Skill`, `load_from_dir/1`) | High | 3 days |
| Vertex AI Memory Bank store | Medium | 2 days |
| First-class streaming API (`ADK.Runner.stream/5`) | Medium | 2 days |
| Planner agent | Medium | 2 days |
| HITL approval pattern | Medium | 2 days |
| Agent Registry | Medium | 1 day |
| A2A interceptors | Low | 1 day |
| LiteLLM proxy backend | Low | 0.5 day |
| User Personas in Eval | Low | 1 day |
| Built-in code execution tool | Low | 0.5 day |

---

## Notes

- Python ADK is moving fast (~1 major release per week). This gap analysis will need updates.
- Most gaps are "nice to have" — the core loop is complete.
- HITL + Token compaction are the most impactful missing features for production use.
- Elixir's BEAM advantages (OTP, Oban, real parallelism) are **real differentiators** — lean into them.
