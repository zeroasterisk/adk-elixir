# Changelog

## 0.1.0 (2026-03-05)

Initial prototype.

### Added
- `ADK` facade module with `new/2`, `run/3`, `chat/3`, `sequential/2`
- `ADK.Agent` behaviour
- `ADK.Agent.LlmAgent` — LLM agent with tool call loop
- `ADK.Agent.SequentialAgent` — sequential pipeline agent
- `ADK.Tool` behaviour
- `ADK.Tool.FunctionTool` — wrap any function as a tool
- `ADK.Tool.Declarative` — `@tool` macro for declarative tool definition
- `ADK.Event` — universal event struct
- `ADK.EventActions` — state deltas, transfers, escalation
- `ADK.Context` — immutable invocation context
- `ADK.Session` — GenServer per session with state tracking
- `ADK.State.Delta` — immutable state diffing
- `ADK.Runner` — orchestration layer
- `ADK.LLM` behaviour + `ADK.LLM.Mock` for testing
- 50 tests (38 unit + 12 doctests)
