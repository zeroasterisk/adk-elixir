# Python ADK v1.27.0 Comparison — v4 Review

**Date:** 2026-03-13
**Reviewer:** Automated (Zaf)
**Python ADK:** v1.27.0 (released 2026-03-12)
**Elixir ADK:** v0.1.0 (commit 91cf9d1, branch main)

## Overview

This is the v4 feature comparison between ADK Elixir and Python ADK v1.27.0.
Coverage is estimated at **~70%** (weighted by importance), up from ~65% in v3.

## Changes Since v3

### Gaps Closed (Quick Wins)

1. **`@spec` annotations** — Added to 7 modules (3 compressors, 3 LLM backends, Artifact.InMemory)
2. **`skip_summarization` on EventActions** — New field for context compaction control (Python parity)
3. **`end_of_agent` on EventActions** — New field for agent lifecycle signaling (Python parity)
4. **Flaky adk.server test fixed** — Pre-existing `function_exported?` failure resolved with `Code.ensure_loaded!`

### New Python ADK v1.27.0 Features Not Yet in Elixir

| Feature | Impact | Effort | Priority |
|---------|--------|--------|----------|
| A2A rewrite (RemoteA2aAgent as agent) | Medium | Large | P1 |
| A2A request interceptors | Low | Medium | P2 |
| Durable runtime support | Medium | Large | P3 |
| AuthProviderRegistry | Medium | Medium | P1 |
| BashTool | Medium | Small | P2 |
| `adk optimize` command | Low | Large | P3 |
| UiWidget in EventActions | Low | Small | P3 |
| GCS filesystem for Skills | Low | Medium | P2 |
| GetSessionConfig in RunConfig | Medium | Small | P1 |
| Anthropic PDF + streaming | Low | Medium | P2 |
| LiteLLM output schema + thought preservation | N/A | N/A | N/A (no LiteLLM) |
| BigQuery Agent Analytics enhancements | Low | Large | P3 |
| Bigtable cluster tools | Low | Large | P3 |
| GKE Code Executor enhancements | Low | Large | P3 |
| OTel semantic convention enhancements | Low | Small | P2 |

### Coverage Breakdown

See full comparison at `~/.openclaw/workspace/memory/adk-elixir-feature-comparison-v4.md`.

## Commits

- `aaf7ac2` — Add @spec to public functions, add skip_summarization to EventActions
- `91cf9d1` — Add end_of_agent to EventActions, fix flaky adk.server test
