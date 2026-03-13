# ADK Real Benchmarks — Elixir vs Python

Measures pure framework overhead with mocked LLMs (no real API calls).

## 15 Scenarios

| # | Scenario | What it tests |
|---|----------|---------------|
| 1 | Single agent + 3 tools, 10 turns | Basic agent loop |
| 2 | 3-agent sequential pipeline | Agent handoff |
| 3 | Parallel fan-out (5 agents) | Concurrent execution |
| 4 | 100 concurrent sessions | Session scaling |
| 5 | Context compression (200 msgs) | TokenBudget compaction |
| 6 | Agent transfer chain (A→B→C) | Transfer routing |
| 7 | Context compression (2,000 msgs) | Compressor at scale |
| 8 | Large fan-out (20 agents) | Stress concurrent spawning |
| 9 | Deep fan-out (5×5 = 25 agents) | Hierarchical concurrency |
| 10 | Complex workflow (Seq→Par→Loop) | Mixed agent types |
| 11 | Long transfer chain (6 agents) | Extended routing |
| 12 | Transfer with backtracking | Back-and-forth routing |
| 13 | Error handling / crash recovery | Error path overhead |
| 14 | 500 concurrent sessions | Push session limits |
| 15 | Mixed load (50 pipelines) | Realistic production sim |

## Setup

### Elixir

```bash
cd adk-elixir   # project root
mix deps.get
mix compile
```

### Python

```bash
cd benchmarks/real
python3 -m venv .venv
source .venv/bin/activate
pip install google-adk
# or: uv venv .venv && uv pip install google-adk
```

## Running

### Individual

```bash
# Elixir (from project root)
mix run benchmarks/real/elixir_bench.exs

# Python (from benchmarks/real/)
cd benchmarks/real
source .venv/bin/activate
python python_bench.py
```

### Both at once

```bash
bash benchmarks/real/run_all.sh
```

## Output

- `elixir_results.json` — Benchee stats (mean, median, p99, stddev, IPS, memory)
- `python_results.json` — Python harness stats (same metrics)
- Console output with formatted summary

## Notes

- Both benchmarks use **identical canned responses** per scenario
- Elixir uses `ADK.LLM.Mock` (process dictionary); Python uses a custom `MockLlm` (thread-local)
- Elixir: Benchee with 2s warmup + 10s measurement; Python: 20 warmup + 200 iterations
- No network I/O — pure framework overhead measurement
