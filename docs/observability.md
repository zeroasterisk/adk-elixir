# ADK Elixir — Observability Guide

Telemetry, logging, tracing, and debugging with `ADK.Telemetry`.

---

## Overview

ADK Elixir emits structured telemetry events at every key execution point
via Erlang's `:telemetry` library. You can attach handlers for:

- **Metrics** (Prometheus, StatsD, Datadog)
- **Distributed tracing** (OpenTelemetry, Honeycomb)
- **Structured logging** (Logger, Logflare)
- **Debug inspection** (ADK's built-in span store)

All events follow the `[:adk, <component>, <stage>]` naming convention,
compatible with `:telemetry.span/3`.

---

## Event Catalog — `ADK.Telemetry.Contract`

| Event                     | When fired                        |
|---------------------------|-----------------------------------|
| `[:adk, :runner, :start]` | `Runner.run/4` begins             |
| `[:adk, :runner, :stop]`  | `Runner.run/4` completes          |
| `[:adk, :runner, :exception]` | `Runner.run/4` raises        |
| `[:adk, :agent, :start]`  | Individual agent begins           |
| `[:adk, :agent, :stop]`   | Individual agent completes        |
| `[:adk, :agent, :exception]` | Individual agent raises        |
| `[:adk, :llm, :start]`    | Before LLM API call               |
| `[:adk, :llm, :stop]`     | After LLM API call completes      |
| `[:adk, :llm, :exception]`| LLM API call raises               |
| `[:adk, :tool, :start]`   | Before tool execution             |
| `[:adk, :tool, :stop]`    | After tool execution              |
| `[:adk, :tool, :exception]`| Tool execution raises            |
| `[:adk, :session, :start]`| Session created                   |
| `[:adk, :session, :stop]` | Session ended                     |

Get all event names programmatically:

```elixir
ADK.Telemetry.Contract.all_events()
# => [[:adk, :runner, :start], [:adk, :runner, :stop], ...]
```

---

## Standard Metadata

Every event includes:

| Key           | Type     | Description                    |
|---------------|----------|--------------------------------|
| `:agent_name` | `String` | Active agent's name            |
| `:app_name`   | `String` | Runner's app name              |
| `:session_id` | `term`   | Session identifier             |
| `:user_id`    | `String` | (runner/session events)        |
| `:model`      | `String` | LLM model (llm events)         |
| `:tool_name`  | `String` | Tool name (tool events)        |

Exception events also carry `:kind`, `:reason`, and `:stacktrace`.

---

## Attaching a Handler

### Minimal Example

```elixir
:telemetry.attach_many(
  "my-adk-logger",
  ADK.Telemetry.Contract.all_events(),
  &MyApp.TelemetryHandler.handle_event/4,
  nil
)
```

### Handler Module

```elixir
defmodule MyApp.TelemetryHandler do
  require Logger

  def handle_event([:adk, :agent, :stop], %{duration: duration}, meta, _config) do
    Logger.info("agent=#{meta.agent_name} duration_ms=#{System.convert_time_unit(duration, :native, :millisecond)}")
  end

  def handle_event([:adk, :llm, :stop], %{duration: duration}, meta, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    Logger.debug("llm_call model=#{meta.model} agent=#{meta.agent_name} duration_ms=#{duration_ms}")
  end

  def handle_event([:adk, :tool, :stop], %{duration: duration}, meta, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    Logger.debug("tool_call tool=#{meta.tool_name} agent=#{meta.agent_name} duration_ms=#{duration_ms}")
  end

  def handle_event([:adk, :runner, :exception], _measurements, meta, _config) do
    Logger.error("runner_error agent=#{meta.agent_name} reason=#{inspect(meta.reason)}")
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok
end
```

Attach in your application startup:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  MyApp.TelemetryHandler.attach()
  # ...
end
```

---

## Span Emission (Internal API)

ADK uses `ADK.Telemetry.Contract` helpers internally. You can use the same
helpers in your custom agents or tools:

```elixir
# Emit a span around a block of work
ADK.Telemetry.Contract.agent_span(%{agent_name: "my_agent", app_name: "app", session_id: "s1"}, fn ->
  do_some_work()
end)

# Or emit start/stop manually
:telemetry.execute([:adk, :agent, :start], %{monotonic_time: System.monotonic_time()}, meta)
result = do_work()
:telemetry.execute([:adk, :agent, :stop], %{duration: elapsed, monotonic_time: System.monotonic_time()}, meta)
result
```

---

## Built-in Debug Handler — `ADK.Telemetry.DebugHandler`

ADK ships a debug span collector that automatically captures all `:stop` events
into an ETS-backed store. This powers the `/adk/debug/trace/` HTTP endpoints.

### Attach (automatic in dev/test)

```elixir
ADK.Telemetry.DebugHandler.attach()
```

The handler is attached automatically when `ADK.Application` starts.

### Query Spans

```elixir
alias ADK.Telemetry.SpanStore

# Get span for a specific event ID
{:ok, span} = SpanStore.get_event_span("evt-abc123")
# => %{name: "adk.agent.stop", duration_ms: 42.5, attributes: %{...}}

# Get all spans for a session
spans = SpanStore.get_session_spans("sess-xyz")
# => [%{name: "adk.runner.stop", ...}, %{name: "adk.agent.stop", ...}]
```

### Span Format

```elixir
%{
  name: "adk.agent.stop",
  span_id: "a1b2c3d4",
  trace_id: "e5f6g7h8",
  start_time: 1710000000.0,    # Unix float seconds
  end_time: 1710000001.5,
  duration_ms: 1500.0,
  attributes: %{
    agent_name: "my_agent",
    session_id: "sess-1",
    app_name: "my_app"
  }
}
```

---

## OpenTelemetry Integration

Use [`opentelemetry_telemetry`](https://hex.pm/packages/opentelemetry_telemetry) to bridge ADK events into OTEL traces:

```elixir
# mix.exs deps
{:opentelemetry, "~> 1.3"},
{:opentelemetry_api, "~> 1.3"},
{:opentelemetry_exporter, "~> 1.6"}

# config/config.exs
config :opentelemetry, :processors,
  otel_batch_processor: %{exporter: {:opentelemetry_exporter, %{}}}
```

Then bridge from `:telemetry` events to OTEL spans in your handler:

```elixir
def handle_event([:adk, :runner, :start], measurements, meta, _) do
  ctx = OpenTelemetry.Tracer.start_span("adk.runner", %{
    attributes: Map.to_list(meta)
  })
  Process.put(:adk_otel_ctx, ctx)
end

def handle_event([:adk, :runner, :stop], _measurements, _meta, _) do
  ctx = Process.get(:adk_otel_ctx)
  OpenTelemetry.Tracer.end_span(ctx)
end
```

---

## Metrics with Telemetry.Metrics

Use [`telemetry_metrics`](https://hex.pm/packages/telemetry_metrics) for Prometheus/StatsD export:

```elixir
# lib/my_app/telemetry.ex
defmodule MyApp.Telemetry do
  import Telemetry.Metrics

  def metrics do
    [
      # LLM call latency histogram
      distribution("adk.llm.stop.duration",
        event_name: [:adk, :llm, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:model, :agent_name]
      ),

      # Tool call counter
      counter("adk.tool.stop.count",
        event_name: [:adk, :tool, :stop],
        tags: [:tool_name, :agent_name]
      ),

      # Runner duration summary
      summary("adk.runner.stop.duration",
        event_name: [:adk, :runner, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:app_name]
      ),

      # Error counter
      counter("adk.runner.exception.count",
        event_name: [:adk, :runner, :exception],
        tags: [:agent_name]
      )
    ]
  end
end
```

---

## Logging

ADK uses Elixir's standard `Logger`. Enable structured logs:

```elixir
# config/config.exs
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :agent_name, :session_id]
```

For JSON logs (e.g., Cloud Logging / Datadog):

```elixir
# Add to deps: {:logger_json, "~> 5.1"}
config :logger,
  backends: [LoggerJSON]

config :logger_json, :backend,
  metadata: :all,
  formatter: LoggerJSON.Formatters.GoogleCloudLogger
```

---

## Debug Endpoints (Dev Server)

When using the ADK dev server or Phoenix integration:

```
GET /adk/debug/sessions           # list active sessions
GET /adk/debug/sessions/:id       # session details + events
GET /adk/debug/trace/:session_id  # telemetry spans for session
```

These match Python ADK's debug API surface for tooling compatibility.

---

## Tips

- **Sampling**: Attach handlers only to `:stop` events to avoid double-counting start/stop.
- **TTL**: `SpanStore` automatically prunes entries older than 30 minutes (configurable via `config :adk, :span_store_ttl_ms, 1_800_000`).
- **Async handlers**: `:telemetry` handlers run synchronously in the calling process. For expensive work (DB writes, HTTP calls), use `Task.start/1` inside your handler.
- **Testing telemetry**: Use `:telemetry_test` or collect events manually with `:telemetry.attach/4` in test setup.
