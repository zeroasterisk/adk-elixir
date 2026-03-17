# Telemetry

ADK emits [`:telemetry`](https://hex.pm/packages/telemetry) events at every
key execution point — runner invocations, agent execution, LLM calls, tool
calls, and session lifecycle. These events form the **control plane data
surface** for observability, metrics, tracing, and debugging.

## Event Reference

All events follow the `[:adk, <component>, <stage>]` naming convention.

### Runner Events — `[:adk, :runner, ...]`

Wraps the full `ADK.Runner.run/4` invocation.

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:adk, :runner, :start]` | `monotonic_time`, `system_time` | `app_name`, `agent_name`, `session_id`, `user_id` |
| `[:adk, :runner, :stop]` | `duration`, `monotonic_time` | same as start |
| `[:adk, :runner, :exception]` | `duration`, `monotonic_time` | same + `kind`, `reason`, `stacktrace` |

### Agent Events — `[:adk, :agent, ...]`

Wraps individual agent execution (LlmAgent, Custom, Sequential, Parallel, Loop).

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:adk, :agent, :start]` | `monotonic_time`, `system_time` | `agent_name`, `session_id`, `app_name` |
| `[:adk, :agent, :stop]` | `duration`, `monotonic_time` | same as start |
| `[:adk, :agent, :exception]` | `duration`, `monotonic_time` | same + `kind`, `reason`, `stacktrace` |

Agent stop events may include additional OTel semantic attributes:
- `gen_ai.system` — e.g. `"gcp.vertex.agent"`
- `gen_ai.operation.name` — e.g. `"invoke_agent"`
- `gen_ai.agent.name` — agent name
- `gen_ai.conversation.id` — session identifier

### Tool Events — `[:adk, :tool, ...]`

Wraps tool function calls.

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:adk, :tool, :start]` | `monotonic_time`, `system_time` | `tool_name`, `agent_name`, `session_id` |
| `[:adk, :tool, :stop]` | `duration`, `monotonic_time` | same as start |
| `[:adk, :tool, :exception]` | `duration`, `monotonic_time` | same + `kind`, `reason`, `stacktrace` |

### LLM Events — `[:adk, :llm, ...]`

Wraps LLM API calls.

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:adk, :llm, :start]` | `monotonic_time`, `system_time` | `model`, `agent_name`, `session_id` |
| `[:adk, :llm, :stop]` | `duration`, `monotonic_time` | same as start |
| `[:adk, :llm, :exception]` | `duration`, `monotonic_time` | same + `kind`, `reason`, `stacktrace` |

LLM stop events may include:
- `gen_ai.response.input_tokens` — input token count
- `gen_ai.response.output_tokens` — output token count
- `gen_ai.response.finish_reasons` — finish reason(s)

### Session Events — `[:adk, :session, ...]`

Tracks session lifecycle (creation and teardown).

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:adk, :session, :start]` | `monotonic_time`, `system_time` | `app_name`, `session_id`, `user_id` |
| `[:adk, :session, :stop]` | `duration`, `monotonic_time` | same as start |

## Attaching Handlers

### Manual handler

```elixir
:telemetry.attach_many(
  "my-handler",
  ADK.Telemetry.Contract.all_events(),
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata})
  end,
  nil
)
```

### Built-in Logger handler

For development, attach the default Logger handler:

```elixir
ADK.Telemetry.DefaultHandler.attach()
```

This logs all events at `:debug` level with timing info. Detach with:

```elixir
ADK.Telemetry.DefaultHandler.detach()
```

### StatsD / Prometheus via `telemetry_metrics`

Use [`:telemetry_metrics`](https://hex.pm/packages/telemetry_metrics) to define
metrics from ADK events:

```elixir
defmodule MyApp.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {TelemetryMetricsStatsd, metrics: metrics()}
      # Or: {TelemetryMetricsPrometheus, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      # Runner
      summary("adk.runner.stop.duration",
        unit: {:native, :millisecond},
        tags: [:app_name, :agent_name]
      ),
      counter("adk.runner.exception.duration",
        tags: [:app_name, :agent_name]
      ),

      # Agent
      summary("adk.agent.stop.duration",
        unit: {:native, :millisecond},
        tags: [:agent_name]
      ),

      # LLM
      summary("adk.llm.stop.duration",
        unit: {:native, :millisecond},
        tags: [:model, :agent_name]
      ),
      counter("adk.llm.exception.duration",
        tags: [:model]
      ),

      # Tool
      summary("adk.tool.stop.duration",
        unit: {:native, :millisecond},
        tags: [:tool_name, :agent_name]
      ),
      counter("adk.tool.exception.duration",
        tags: [:tool_name]
      ),

      # Session
      summary("adk.session.stop.duration",
        unit: {:native, :millisecond},
        tags: [:app_name]
      )
    ]
  end
end
```

### Prometheus with `PromEx`

If you use [PromEx](https://hex.pm/packages/prom_ex), create a custom plugin:

```elixir
defmodule MyApp.PromEx.ADKPlugin do
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    Event.build(:adk_metrics, [
      distribution(
        [:adk, :runner, :duration, :milliseconds],
        event_name: [:adk, :runner, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:app_name, :agent_name]
      ),
      distribution(
        [:adk, :llm, :duration, :milliseconds],
        event_name: [:adk, :llm, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:model]
      )
    ])
  end
end
```

## Contract Module

`ADK.Telemetry.Contract` is the canonical source of truth for all event names:

```elixir
# All 14 events
ADK.Telemetry.Contract.all_events()

# Just stop events (for metrics handlers)
ADK.Telemetry.Contract.stop_events()

# Just exception events (for error tracking)
ADK.Telemetry.Contract.exception_events()

# Category-specific
ADK.Telemetry.Contract.runner_events()
ADK.Telemetry.Contract.agent_events()
ADK.Telemetry.Contract.tool_events()
ADK.Telemetry.Contract.llm_events()
ADK.Telemetry.Contract.session_events()
```

### Span Helpers

Wrap any function with telemetry start/stop/exception:

```elixir
# Runner span
ADK.Telemetry.Contract.runner_span(
  %{app_name: "myapp", agent_name: "bot", session_id: "s1", user_id: "u1"},
  fn -> do_runner_work() end
)

# Session span
ADK.Telemetry.Contract.session_span(
  %{app_name: "myapp", session_id: "s1", user_id: "u1"},
  fn -> start_session() end
)

# Also available: agent_span/2, tool_span/2, llm_span/2
```

### Metadata Builders

Convenience functions for building correctly-shaped metadata:

```elixir
meta = ADK.Telemetry.Contract.runner_metadata(runner, session_id, user_id)
meta = ADK.Telemetry.Contract.session_metadata(app_name, session_id, user_id)
meta = ADK.Telemetry.Contract.agent_metadata(agent_name, session_id, app_name)
meta = ADK.Telemetry.Contract.tool_metadata(tool_name, agent_name, session_id)
meta = ADK.Telemetry.Contract.llm_metadata(model, agent_name, session_id)
```

## Integration with Phoenix Telemetry

If your Phoenix app already uses `:telemetry`, ADK events integrate naturally.
In your `Telemetry` supervisor:

```elixir
defp metrics do
  # Your existing Phoenix metrics...
  phoenix_metrics() ++
  # ADK metrics
  [
    summary("adk.runner.stop.duration", unit: {:native, :millisecond}),
    summary("adk.llm.stop.duration", unit: {:native, :millisecond}, tags: [:model]),
    summary("adk.tool.stop.duration", unit: {:native, :millisecond}, tags: [:tool_name])
  ]
end
```

## Debug Trace UI

ADK also ships with `ADK.Telemetry.DebugHandler` and `ADK.Telemetry.SpanStore`
which capture spans in ETS for the built-in debug/trace HTTP endpoints. These
are attached automatically when running `mix adk.server` and provide a
trace-viewer UI at `/debug/trace/`.

## OpenTelemetry

When the `:opentelemetry` SDK is loaded, `ADK.Telemetry.span/3` automatically
creates OTel spans in addition to `:telemetry` events — no configuration needed.
This bridges ADK telemetry into distributed traces (Jaeger, Zipkin, etc.).

See the [OpenTelemetry Erlang docs](https://opentelemetry.io/docs/languages/erlang/)
for SDK setup.
