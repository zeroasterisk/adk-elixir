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
      model: "gemini-flash-latest",
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
    "model" => "gemini-flash-latest",
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

## Scheduled Agent Runs

`ADK.Oban.ScheduledJob` is a thin convenience wrapper for recurring agent runs via the Oban cron plugin. It uses the `:scheduled` queue by default and is designed for system-level background tasks.

### One-Shot Delayed Scheduling

Schedule an agent to run once after a delay:

```elixir
# Run in 60 seconds
ADK.Oban.ScheduledJob.schedule(MyApp.Agents.Cleanup, schedule_in: 60)

# Run at a specific time
ADK.Oban.ScheduledJob.schedule(
  MyApp.Agents.DailyReport,
  scheduled_at: ~U[2026-03-18 09:00:00Z]
)

# With additional options
ADK.Oban.ScheduledJob.schedule(
  MyApp.Agents.Cleanup,
  schedule_in: 3600,
  user_id: "system",
  message: "Run cleanup sweep"
)
```

### Recurring Cron Configuration

Use the Oban cron plugin for recurring schedules:

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [scheduled: 5],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Daily cleanup agent — runs every day at midnight
       {"0 0 * * *", ADK.Oban.ScheduledJob,
        args: %{
          "agent_module" => "MyApp.Agents.Cleanup",
          "app_name" => "my_app",
          "user_id" => "system",
          "message" => "Run daily cleanup: remove stale sessions and free resources"
        }},

       # Hourly monitoring agent
       {"0 * * * *", ADK.Oban.ScheduledJob,
        args: %{
          "agent_module" => "MyApp.Agents.Monitor",
          "app_name" => "my_app",
          "user_id" => "system",
          "message" => "Run hourly health check and report anomalies"
        }}
     ]}
  ]
```

### Example: Daily Cleanup Agent

```elixir
defmodule MyApp.Agents.Cleanup do
  def agent do
    ADK.Agent.LlmAgent.new(
      name: "cleanup",
      model: "gemini-flash-latest",
      instruction: """
      You are a cleanup agent. Your job is to identify and remove stale data,
      expired sessions, and temporary files. Be conservative — only remove
      things older than 24 hours. Report what you cleaned up.
      """
    )
  end
end
```

### Example: Hourly Monitoring Agent

```elixir
defmodule MyApp.Agents.Monitor do
  def agent do
    ADK.Agent.LlmAgent.new(
      name: "monitor",
      model: "gemini-flash-latest",
      instruction: """
      You are a system monitoring agent. Check system health metrics,
      queue depths, error rates, and response times. Alert on anomalies.
      """
    )
  end
end
```

### Inline Agent Config (No Module Needed)

For simple scheduled tasks, skip the module and configure inline:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 6 * * *", ADK.Oban.ScheduledJob,
        args: %{
          "agent_name" => "morning_brief",
          "model" => "gemini-flash-latest",
          "instruction" => "Generate a morning briefing summary.",
          "message" => "What happened overnight? Summarize key events.",
          "user_id" => "system",
          "app_name" => "my_app"
        }}
     ]}
  ]
```

### Telemetry

`ScheduledJob` emits two telemetry events per run:

```elixir
# Attach handlers to observe scheduled job execution
:telemetry.attach_many(
  "scheduled-job-observer",
  [[:adk, :scheduled_job, :start], [:adk, :scheduled_job, :stop]],
  fn
    [:adk, :scheduled_job, :start], _measurements, %{job_id: id, args: args}, _cfg ->
      Logger.info("Scheduled job #{id} starting", args: args)

    [:adk, :scheduled_job, :stop], %{duration: duration}, %{result: result}, _cfg ->
      Logger.info("Scheduled job completed in #{duration}ms", result: result)
  end,
  nil
)
```

### Difference from AgentWorker

| Feature | `AgentWorker` | `ScheduledJob` |
|---------|--------------|----------------|
| **Default queue** | `:agents` | `:scheduled` |
| **Primary use** | User-triggered async jobs | System cron / scheduled tasks |
| **Inline config** | `agent_config` map with `type` key | `agent_name` + `model` keys |
| **Cron support** | Manual setup | Designed for Oban cron plugin |
| **Priority** | Configurable (default 2) | Default Oban priority |
