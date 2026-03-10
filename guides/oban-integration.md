# Oban Integration

Run ADK agents as durable background jobs with automatic retries, scheduling, and persistence — powered by [Oban](https://hexdocs.pm/oban).

## Why Oban + ADK?

In Python, async agent execution requires bolting on Celery or RQ — separate processes, a Redis broker, custom serialization, and fragile worker deployments. Failures mean lost jobs unless you build retry logic yourself.

With Elixir + Oban, you get:

| Feature | Python (Celery/RQ) | Elixir (Oban) |
|---------|-------------------|---------------|
| **Persistence** | Redis (volatile by default) | Postgres (durable) |
| **Retries** | Manual configuration | Built-in with backoff |
| **Scheduling** | Separate beat process | Native `scheduled_at` |
| **Observability** | External tools needed | Oban Web dashboard |
| **Deployment** | Separate worker processes | Same OTP application |
| **Concurrency** | Multi-process, GIL issues | Lightweight BEAM processes |
| **Isolation** | Process crashes kill workers | Process isolation per job |

The key insight: **Oban runs inside your existing Elixir application**. No separate worker deployment, no message broker, no serialization headaches. Agent jobs are just database rows processed by your app's BEAM processes.

## Setup

### 1. Add Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:adk, "~> 0.1"},
    {:oban, "~> 2.18"},
    {:ecto_sql, "~> 3.10"},
    {:postgrex, "~> 0.19"}
  ]
end
```

### 2. Configure Ecto

Generate an Ecto repo if you don't have one:

```bash
mix ecto.gen.repo -r MyApp.Repo
```

Configure it:

```elixir
# config/config.exs
config :my_app, ecto_repos: [MyApp.Repo]

config :my_app, MyApp.Repo,
  url: "postgres://localhost/my_app_dev"
```

### 3. Configure Oban

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [agents: 10]  # 10 concurrent agent jobs
```

Add Oban to your supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Oban, Application.fetch_env!(:my_app, Oban)}
]
```

### 4. Run Oban Migrations

```bash
mix ecto.gen.migration add_oban_jobs_table
```

```elixir
defmodule MyApp.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)
  def down, do: Oban.Migration.down(version: 1)
end
```

```bash
mix ecto.migrate
```

## Usage

### Define an Agent Module

The worker resolves agents via a module that exports an `agent/0` function:

```elixir
defmodule MyApp.Agents.Helper do
  def agent do
    ADK.Agent.LlmAgent.new(
      name: "helper",
      model: "gemini-2.0-flash",
      instruction: "You are a helpful assistant."
    )
  end
end
```

### Enqueue a Job

```elixir
# Using the helper function
ADK.Oban.AgentWorker.enqueue(
  MyApp.Agents.Helper,
  "user-123",
  "Summarize this document",
  session_id: "session-456",
  queue: :agents
)

# Or using Oban directly
%{
  agent_module: "MyApp.Agents.Helper",
  user_id: "user-123",
  message: "Summarize this document",
  session_id: "session-456"
}
|> ADK.Oban.AgentWorker.new(queue: :agents)
|> Oban.insert()
```

### Inline Agent Config

For simple agents, skip the module and pass config directly:

```elixir
%{
  agent_config: %{
    "type" => "llm",
    "name" => "summarizer",
    "model" => "gemini-2.0-flash",
    "instruction" => "Summarize the user's input concisely."
  },
  user_id: "user-123",
  message: "Long text to summarize..."
}
|> ADK.Oban.AgentWorker.new()
|> Oban.insert()
```

### Scheduled Execution

```elixir
# Run in 1 hour
ADK.Oban.AgentWorker.enqueue(
  MyApp.Agents.DailyDigest,
  "user-123",
  "Generate my daily digest",
  schedule_in: 3600
)

# Run at a specific time
ADK.Oban.AgentWorker.enqueue(
  MyApp.Agents.DailyDigest,
  "user-123",
  "Generate my daily digest",
  scheduled_at: ~U[2026-03-11 09:00:00Z]
)
```

### Retries

Oban handles retries automatically. The default is 3 attempts with exponential backoff. Customize per-job:

```elixir
ADK.Oban.AgentWorker.new(
  %{agent_module: "MyApp.Agents.Helper", user_id: "u1", message: "hi"},
  max_attempts: 10
)
```

### Observing Results

Job completion emits telemetry events:

```elixir
:telemetry.attach("oban-agent-results", [:adk, :oban, :job, :complete], fn _event, measurements, metadata, _config ->
  IO.inspect(metadata.events, label: "Agent produced #{measurements.event_count} events")
end, nil)
```

### Priority Queues

Use priorities (0 = highest, 9 = lowest) and separate queues:

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [agents: 10, agents_critical: 5, agents_batch: 3]

# High-priority job
ADK.Oban.AgentWorker.enqueue(agent, user_id, msg, queue: :agents_critical, priority: 0)

# Low-priority batch job
ADK.Oban.AgentWorker.enqueue(agent, user_id, msg, queue: :agents_batch, priority: 9)
```

## Architecture

```
┌─────────────────────────────────────────┐
│           Your Elixir App               │
│                                         │
│  ┌──────────┐  ┌──────────┐            │
│  │ Phoenix  │  │   Oban   │            │
│  │ Endpoint │  │ (queues) │            │
│  └────┬─────┘  └────┬─────┘            │
│       │              │                  │
│       │    ┌─────────▼──────────┐       │
│       └───►│ ADK.Oban.AgentWorker│      │
│            └─────────┬──────────┘       │
│                      │                  │
│              ┌───────▼───────┐          │
│              │  ADK.Runner   │          │
│              │  (per job)    │          │
│              └───────┬───────┘          │
│                      │                  │
│              ┌───────▼───────┐          │
│              │  LLM / Tools  │          │
│              └───────────────┘          │
└─────────────────────────────────────────┘
              │
              ▼
     ┌────────────────┐
     │   PostgreSQL    │
     │  (Oban tables)  │
     └────────────────┘
```

Everything runs in one deployment. No separate worker process, no Redis, no message broker.
