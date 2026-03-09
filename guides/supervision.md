# OTP Supervision Tree

ADK Elixir uses a production-ready OTP supervision tree that showcases BEAM advantages: fault isolation, graceful degradation, and self-healing.

## Tree Structure

```
ADK.Supervisor (rest_for_one)
├── ADK.SessionRegistry        — Elixir Registry for session process lookup
├── ADK.Plugin.Registry        — Agent storing global plugins
├── ADK.Auth.InMemoryStore     — Credential storage (dev/test)
├── ADK.Artifact.InMemory      — Artifact storage (dev/test)
├── ADK.Session.Store.InMemory — ETS-backed session persistence
├── ADK.SessionSupervisor      — DynamicSupervisor for session GenServers
├── ADK.RunnerSupervisor       — Task.Supervisor for async agent executions
└── ADK.LLM.CircuitBreaker     — Circuit breaker for LLM provider calls
```

## Why `rest_for_one`?

The top-level supervisor uses `rest_for_one` because there are ordering dependencies:

1. **Registry** must be alive before sessions can register
2. **Session Store** must be alive before sessions can persist
3. **SessionSupervisor** depends on both

If the Registry crashes and restarts, all downstream processes (sessions, runners) are also restarted, ensuring consistent state.

## Key Components

### Session Registry (`ADK.SessionRegistry`)

Uses Elixir's built-in `Registry` module for O(1) session lookup by `{app_name, user_id, session_id}`. Sessions auto-register on start and auto-deregister on stop via the `:via` tuple mechanism.

```elixir
# Lookup a session
{:ok, pid} = ADK.Session.lookup("my_app", "user1", "sess_abc")

# Sessions register automatically via start_supervised
{:ok, pid} = ADK.Session.start_supervised(
  app_name: "my_app", user_id: "user1", session_id: "sess_abc"
)
```

### Session Processes

Each active session is a `GenServer` under `ADK.SessionSupervisor` (DynamicSupervisor). Sessions use `restart: :temporary` — they are not automatically restarted on crash since they're created on-demand by runners.

**Graceful shutdown:** Sessions with `auto_save: true` persist their state to the configured store in `terminate/2` before stopping.

### Runner Supervisor (`ADK.RunnerSupervisor`)

A `Task.Supervisor` for async agent executions. Benefits:

- **Fault isolation:** A crashing agent run doesn't affect other runs
- **Monitoring:** The supervisor tracks all active tasks
- **Backpressure:** Configurable `max_restarts` prevents cascade failures

```elixir
# Async run under supervision
{:ok, pid} = ADK.Runner.Async.run(runner, "user1", "sess1", "hello")

# Or get a Task struct for awaiting
task = ADK.Runner.Async.run_task(runner, "user1", "sess1", "hello")
events = Task.await(task)
```

### Circuit Breaker (`ADK.LLM.CircuitBreaker`)

Protects against LLM provider outages. After N consecutive failures, the circuit opens and fast-fails requests for a configurable timeout before testing recovery.

### Credential & Artifact Stores

In-memory implementations are started by default for development. In production, swap them out via configuration:

```elixir
config :adk,
  start_credential_store: false,  # use your own supervised store
  start_artifact_store: false
```

## Configuration

```elixir
config :adk,
  start_credential_store: true,
  start_artifact_store: true,
  start_circuit_breaker: true,
  circuit_breaker: [
    failure_threshold: 5,
    reset_timeout_ms: 60_000
  ]
```

## For Generated Projects (`mix adk.new`)

Generated projects don't need their own supervision tree for ADK — the library's `ADK.Application` starts automatically as a dependency. Your application supervisor handles your own concerns (Phoenix, Ecto, etc.) while ADK manages its own tree.
