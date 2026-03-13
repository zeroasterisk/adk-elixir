# ADK Benchmarking Report: Elixir/BEAM vs Python ADK

**Date:** 2026-03-13 (updated with real measurements)
**Author:** Zaf (research, implementation & benchmarking)
**Project:** [ADK Elixir](https://github.com/zeroasterisk/adk-elixir)
**Status:** v2.0 — Real measured benchmarks with mocked LLMs

---

## Executive Summary

| Dimension | Python ADK | Elixir ADK | Elixir Speedup | Winner |
|---|---|---|---|---|
| **Single agent + tools (10 turns)** | 54,832 µs | 2,023 µs | **27x** | **Elixir** |
| **Sequential pipeline (3 agents)** | 5,107 µs | 203 µs | **25x** | **Elixir** |
| **Parallel fan-out (5 agents)** | 7,170 µs | 376 µs | **19x** | **Elixir** |
| **100 concurrent sessions** | 152,598 µs | 3,280 µs | **47x** | **Elixir** |
| **Context compression (200 msgs)** | 5,627 µs | 42 µs | **134x** | **Elixir** |
| **Agent transfer chain (A→B→C)** | 9,233 µs | 298 µs | **31x** | **Elixir** |

**Key takeaway:** With LLM latency removed (mocked), Elixir ADK's framework overhead is **19–134x lower** than Python ADK across all scenarios. The BEAM's lightweight processes, preemptive scheduling, and efficient pattern matching dominate pure framework operations.

> **Important caveat:** In production, LLM API latency (500ms–5s) dominates total wall-clock time. These benchmarks isolate *framework overhead only*. For a single agent making one LLM call, the practical difference is negligible. The advantage compounds with concurrent agents and multi-step pipelines.

---

## Methodology

### Mock LLM Approach

Both benchmarks use a mock LLM that returns canned responses without any network I/O, isolating pure framework overhead:

- **Elixir:** `ADK.LLM.Mock` (built-in module using process dictionary for response queues)
- **Python:** Custom `MockLlm` subclass of `BaseLlm` registered via `LLMRegistry`, using thread-local response queues

Both mocks return **identical canned responses** for each scenario — same text, same function calls, same tool arguments. The only code path bypassed is the HTTP call to Gemini/OpenAI.

### Measurement Methodology

- **Elixir:** [Benchee](https://github.com/bencheeorg/benchee) v1.5 — 2s warmup, 10s measurement per scenario, with memory measurement. Statistical analysis by Benchee (mean, median, p99, std dev, IPS).
- **Python:** Custom harness — 20 warmup iterations + 200 measured iterations per scenario. Timing via `time.perf_counter_ns()`, memory via `tracemalloc`.

### Environment

- **Hardware:** Docker container on NAS (always-on server)
- **OS:** Debian 12 (bookworm), Linux 6.1.120+ x86_64
- **Elixir:** 1.17.3 / OTP 27 (BEAM)
- **Python:** 3.14.3 (CPython)
- **Elixir ADK:** v0.1.0 (local build)
- **Python ADK:** `google-adk` latest from PyPI

### What's Measured

Each scenario measures the **complete framework round-trip**: session creation, context assembly, instruction compilation, mock LLM call dispatch, response parsing, tool execution (if any), event generation, and session state updates. The only thing removed is network I/O to the LLM API.

---

## Detailed Results

### Scenario 1: Single Agent + 3 Tools, 10-Turn Conversation

*Measures basic agent loop overhead — the most common ADK usage pattern.*

Each turn: user message → LLM calls `lookup` tool → tool executes → LLM responds with text. Repeated 10 times with separate sessions.

| Metric | Python ADK | Elixir ADK | Ratio |
|---|---|---|---|
| **Mean** | 54,832 µs | 2,023 µs | 27.1x |
| **Median** | 54,740 µs | 1,978 µs | 27.7x |
| **P99** | 58,441 µs | 2,637 µs | 22.2x |
| **Std Dev** | 690 µs | 143 µs | 4.8x |
| **IPS** | 18.2 | 494.4 | 27.1x |
| **Memory (mean)** | 249 KB | 373 KB | 0.67x |
| **Samples** | 200 | 4,940 | — |

**Analysis:** Elixir is ~27x faster per 10-turn conversation. Python's overhead comes from asyncio event loop scheduling, pydantic model validation on every event/response, and the deep call stack through request processors (12 sequential stages). Elixir's pattern matching and GenServer message passing are dramatically lighter.

Memory is slightly higher for Elixir here because Benchee captures the full BEAM process allocation including the 10 session GenServers, whereas Python's tracemalloc captures heap delta only.

### Scenario 2: 3-Agent Sequential Pipeline

*Measures agent handoff overhead — research → write → edit pipeline.*

| Metric | Python ADK | Elixir ADK | Ratio |
|---|---|---|---|
| **Mean** | 5,107 µs | 203 µs | 25.1x |
| **Median** | 5,082 µs | 196 µs | 25.9x |
| **P99** | 5,520 µs | 286 µs | 19.3x |
| **Std Dev** | 105 µs | 23 µs | 4.6x |
| **IPS** | 195.8 | 4,918.4 | 25.1x |
| **Memory (mean)** | 69 KB | 37 KB | 1.9x |

**Analysis:** Sequential agent handoff in Elixir is 25x faster. Each agent transition in Python involves context rebuilding, pydantic re-validation, and asyncio task scheduling. In Elixir, it's a simple function call with pattern matching on the agent struct.

### Scenario 3: Parallel Fan-Out (5 Sub-Agents)

*Measures concurrent agent execution — ParallelAgent with 5 workers.*

| Metric | Python ADK | Elixir ADK | Ratio |
|---|---|---|---|
| **Mean** | 7,170 µs | 376 µs | 19.1x |
| **Median** | 7,147 µs | 383 µs | 18.7x |
| **P99** | 7,721 µs | 497 µs | 15.5x |
| **Std Dev** | 228 µs | 44 µs | 5.2x |
| **IPS** | 139.5 | 2,661.1 | 19.1x |
| **Memory (mean)** | 188 KB | 21 KB | 8.9x |

**Analysis:** 19x faster with 8.9x less memory. Python's `asyncio.gather()` adds scheduling overhead even for cooperative tasks. Elixir's `Task.async_stream` with BEAM preemptive scheduling runs truly concurrent. Memory difference is notable: each Python agent creates substantial pydantic model overhead, while Elixir processes are ~2-4 KB each.

### Scenario 4: 100 Concurrent Sessions

*Measures session/process scaling — same agent, 100 simultaneous users.*

| Metric | Python ADK | Elixir ADK | Ratio |
|---|---|---|---|
| **Mean** | 152,598 µs | 3,280 µs | 46.5x |
| **Median** | 151,561 µs | 3,093 µs | 49.0x |
| **P99** | 177,609 µs | 6,485 µs | 27.4x |
| **Std Dev** | 4,944 µs | 806 µs | 6.1x |
| **IPS** | 6.6 | 304.9 | 46.5x |
| **Memory (mean)** | 1,031 KB | 148 KB | 6.9x |

**Analysis:** The most dramatic difference — **47x faster, 7x less memory**. This is where BEAM's architecture truly shines. 100 concurrent BEAM processes (each a lightweight GenServer session) is trivial for the VM — it's designed for millions. Python's asyncio event loop serializes all 100 sessions through a single thread, adding cumulative scheduling overhead. The GIL prevents any true parallelism for CPU-bound work (JSON parsing, validation).

### Scenario 5: Context Compression (200 Messages)

*Measures TokenBudget compaction — 200-message history trimmed to 1000 tokens.*

| Metric | Python ADK | Elixir ADK | Ratio |
|---|---|---|---|
| **Mean** | 5,627 µs | 42 µs | 134.0x |
| **Median** | 5,616 µs | 34 µs | 165.2x |
| **P99** | 5,864 µs | 118 µs | 49.7x |
| **Std Dev** | 83 µs | 21 µs | 4.0x |
| **IPS** | 177.7 | 23,889.8 | 134.4x |
| **Memory (mean)** | 300 KB | 59 KB | 5.1x |

**Analysis:** The largest speedup — **134x**. Context compression is pure data processing: iterating message lists, estimating token counts (char_count ÷ 4), partitioning by role, and selecting messages within budget. Elixir's pattern matching, list comprehensions, and immutable data structures with structural sharing are extremely efficient for this workload. Python's overhead comes from pydantic Content/Part object creation for all 200 messages, plus the interpreted loop overhead.

Note: Python's scenario includes `types.Content` object creation (matching the Elixir side which uses maps), whereas a raw Python list-of-dicts would be faster. We used the real ADK types to keep the comparison fair.

### Scenario 6: Agent Transfer Chain (A → B → C)

*Measures transfer routing — multi-hop agent delegation.*

| Metric | Python ADK | Elixir ADK | Ratio |
|---|---|---|---|
| **Mean** | 9,233 µs | 298 µs | 31.0x |
| **Median** | 9,192 µs | 293 µs | 31.4x |
| **P99** | 10,109 µs | 377 µs | 26.8x |
| **Std Dev** | 182 µs | 19 µs | 9.6x |
| **IPS** | 108.3 | 3,357.2 | 31.0x |
| **Memory (mean)** | 160 KB | 63 KB | 2.5x |

**Analysis:** 31x faster. Each transfer involves: LLM response with function_call → tool dispatch → transfer signal → agent tree lookup → context switch → new agent execution. Python ADK processes transfers through the full Runner loop including session event writes, invocation context rebuilding, and pydantic validation at each hop. Elixir's implementation is a pattern match on the transfer signal followed by a direct function call to the target agent's `run/2`.

---

## Why Is Elixir So Much Faster?

The 19–134x speedup isn't about "Elixir is a faster language." It's about architectural differences:

### 1. Process Model
- **Python:** Single-threaded asyncio event loop. All 100 concurrent sessions share one thread. CPU-bound work (validation, serialization) serializes through the GIL.
- **Elixir:** BEAM spawns a lightweight process per session (~2KB). Preemptive scheduling across all CPU cores. No GIL equivalent.

### 2. Data Handling
- **Python:** Pydantic v2 models with runtime validation on every `Content`, `Part`, `Event`, and `LlmResponse`. Each object construction validates types, defaults, and constraints.
- **Elixir:** Plain maps and structs with compile-time typespecs. Pattern matching destructures data in constant time. No runtime validation overhead per message.

### 3. Framework Depth
- **Python ADK:** 12 sequential request processors, deep class hierarchy (BaseLlm → GoogleLlm, BaseAgent → LlmAgent), callback chains through `__call__` protocols.
- **Elixir ADK:** Flat function pipeline with protocol dispatch. `ADK.Agent.run/2` → `InstructionCompiler.compile/2` → `LLM.generate/2` → pattern match response. Fewer indirections.

### 4. Session Management
- **Python:** In-memory dict lookup, asyncio lock for concurrent access, full object graph per session.
- **Elixir:** GenServer per session (2-4KB), Registry-based O(1) lookup, process isolation means no locks needed.

### 5. String/Binary Operations
- **Python:** String concatenation for prompt building, `json.dumps`/`json.loads` for serialization.
- **Elixir:** IO lists and binary pattern matching avoid copying. Jason (NIF-backed JSON) is ~2x faster than Python's json module.

---

## Memory Comparison

| Scenario | Python Memory | Elixir Memory | Ratio |
|---|---|---|---|
| Single agent (10 turns) | 249 KB | 373 KB | 0.67x |
| Sequential pipeline | 69 KB | 37 KB | 1.9x |
| Parallel fan-out (5) | 188 KB | 21 KB | **8.9x** |
| 100 concurrent sessions | 1,031 KB | 148 KB | **6.9x** |
| Context compression | 300 KB | 59 KB | **5.1x** |
| Transfer chain | 160 KB | 63 KB | **2.5x** |

Memory comparison is nuanced: Benchee measures BEAM process allocation (which includes GenServer overhead), while Python's `tracemalloc` measures heap delta. For single-agent scenarios, the GenServer overhead makes Elixir look comparable. But at scale (100 sessions, parallel agents), Elixir's ~2KB/process vs Python's ~10KB/session shows the architectural advantage.

---

## Production Implications

### When It Matters
- **Multi-agent systems** with 10+ concurrent agents: Elixir's overhead is negligible
- **High-throughput session handling**: 100+ concurrent users → 47x less framework overhead
- **Complex pipelines**: Sequential/parallel agent compositions are 19-25x leaner
- **Rapid iteration**: Agent loop overhead of 200µs vs 5,000µs matters for multi-turn tool use

### When It Doesn't Matter
- **Single agent, single user**: LLM API call (500ms–5s) dominates. The 2ms vs 55ms framework overhead is noise.
- **Simple Q&A bots**: No tools, no transfers, one turn. Framework overhead is irrelevant.

### BEAM-Specific Advantages Not Captured by Benchmarks
- **Fault tolerance:** OTP supervision trees automatically restart crashed agent processes. Python has no equivalent.
- **Hot code upgrades:** Deploy new agent logic without dropping sessions. Python requires full restart.
- **Distribution:** BEAM processes can span nodes natively. Python requires explicit distributed systems (Redis, message queues).
- **Backpressure:** GenServer mailboxes provide natural flow control. asyncio has no built-in backpressure.

---

## Stress Testing (Scenarios 7–15)

Scaled-up scenarios that push framework limits beyond the basic 6 scenarios above.

### Executive Summary — Stress Tests

| Scenario | Description | What it stresses |
|---|---|---|
| 7 | Context compression (2,000 msgs) | 10x message count for compressor |
| 8 | Large fan-out (20 sub-agents) | 4x concurrent processes |
| 9 | Deep fan-out (5×5 = 25 agents) | Nested parallelism |
| 10 | Complex workflow (Seq→Par→Loop) | Mixed agent type composition |
| 11 | Long transfer chain (6 agents) | Extended routing overhead |
| 12 | Transfer with backtracking | Back-and-forth transfer resolution |
| 13 | Error handling / recovery | Error path vs happy path overhead |
| 14 | 500 concurrent sessions | 5x session scaling |
| 15 | Mixed load (50 pipelines + tools) | Realistic production simulation |

### Scenario 7: Context Compression at 2,000 Messages

*Same as Scenario 5 but 10x the messages — 2,000 messages compressed to 1,000-token budget.*

This scenario stresses the TokenBudget compressor with a realistically large conversation history. The 10x increase in message count amplifies list iteration, token estimation, and selection overhead.

**Expected scaling:** ~10x slower than Scenario 5 for both frameworks, with Elixir maintaining its large lead due to efficient list operations and pattern matching.

### Scenario 8: Large Fan-Out (20 Sub-Agents)

*ParallelAgent with 20 sub-agents instead of 5.*

Tests concurrent process spawning at 4x scale. BEAM should handle this trivially (20 processes is nothing), while Python's asyncio.gather with 20 coroutines adds proportionally more scheduling overhead.

### Scenario 9: Deep Fan-Out (5×5 = 25 Agents)

*Nested ParallelAgent — 5 groups of 5 workers.*

This tests hierarchical concurrency: the outer ParallelAgent spawns 5 inner ParallelAgents, each spawning 5 workers. Total: 25 leaf agents + 5 group agents + 1 root = 31 agents. Tests how well the frameworks handle nested concurrent spawning.

### Scenario 10: Complex Workflow (Sequential → Parallel → Loop)

*A realistic pipeline: SequentialAgent containing [LlmAgent, ParallelAgent(3 workers), LoopAgent(2 iterations)].*

This is the most realistic single-pipeline scenario — mixing all three workflow agent types. Tests composition overhead and context passing between different agent types.

### Scenario 11: Long Transfer Chain (A → B → C → D → E → F)

*6-agent transfer chain, double the length of Scenario 6.*

Each hop involves: LLM response parsing → transfer signal detection → agent tree lookup → context switch. 6 hops means 6x the routing overhead. Tests whether transfer resolution scales linearly.

### Scenario 12: Transfer with Backtracking

*Agent transfers that go back and forth: A → B → C, then responses flow back through the chain.*

Tests repeated transfer resolution within the same session. The agent tree must resolve transfers in both directions, testing the robustness of the transfer mechanism under non-linear flow.

### Scenario 13: Error Handling / Crash Recovery

*Tool that raises an exception, caught by the runner, followed by a successful tool call.*

Measures the overhead of the error handling path: exception capture, error event generation, and recovery vs the happy path. Critical for understanding production reliability costs.

### Scenario 14: 500 Concurrent Sessions

*Scale up from 100 (Scenario 4) to 500 simultaneous sessions.*

Pushes session/process limits. BEAM should handle 500 processes with minimal degradation (designed for millions). Python's single-threaded asyncio should show more significant scaling issues as coroutine scheduling overhead accumulates.

### Scenario 15: Mixed Load (Realistic Production Simulation)

*50 concurrent sessions, each running a 3-agent SequentialAgent pipeline with tool calls.*

The closest scenario to real-world production use: multiple users simultaneously running multi-agent pipelines with tools. Combines concurrency stress (50 sessions) with pipeline complexity (3 agents + tool calls per session = ~200 LLM responses total).

---

## Raw Data

Full benchmark results are in:
- `benchmarks/real/elixir_results.json` — Benchee output
- `benchmarks/real/python_results.json` — Python harness output

### Reproducing

```bash
# Elixir
cd adk-elixir
mix run benchmarks/real/elixir_bench.exs

# Python
cd benchmarks/real
. .venv/bin/activate   # or: uv venv .venv && uv pip install google-adk
python python_bench.py
```

---

## Appendix: Canned Responses

Both benchmarks use identical mock responses per scenario:

| Scenario | Response Sequence |
|---|---|
| 1 (tools) | Per turn: `function_call(lookup, {input: "qN"})` → `"Answer for turn N"` |
| 2 (pipeline) | `"Research findings..."` → `"Draft article..."` → `"Edited article..."` |
| 3 (parallel) | 5× `"Result from agent N"` |
| 4 (concurrent) | Per session: `"Response for user N"` |
| 5 (compression) | N/A (data processing only, no LLM call) |
| 6 (transfer) | `transfer_to_agent(B)` → `transfer_to_agent(C)` → `"Final response from C"` |
| 7 (compression 2K) | N/A (data processing only, no LLM call) — 2,000 messages |
| 8 (large fan-out) | 20× `"Result from agent N"` |
| 9 (deep fan-out) | 25× `"Result from deep worker N"` |
| 10 (complex workflow) | `"Step 1..."` → 3× parallel results → 2× loop iterations |
| 11 (long chain) | 5× `transfer_to_agent(X)` → `"Final response from F"` |
| 12 (backtracking) | `transfer(B)` → `transfer(C)` → response → backtrack responses → `transfer(B)` → final |
| 13 (error handling) | `function_call(risky_tool)` [raises] → `function_call(safe_tool)` → `"Recovered"` |
| 14 (500 sessions) | Per session: `"Response for user N"` |
| 15 (mixed load) | Per session: `function_call(process_data)` → 3× agent responses |

Note: Elixir ADK uses per-agent transfer tools (`transfer_to_agent_agent_b`), while Python ADK uses a single `transfer_to_agent` tool with an `agent_name` parameter. Both approaches achieve the same result — this is a documented intentional design difference.
