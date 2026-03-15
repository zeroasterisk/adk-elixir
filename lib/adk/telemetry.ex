defmodule ADK.Telemetry do
  @moduledoc """
  Telemetry events for the ADK pipeline.

  ADK emits `:telemetry` events at key execution points so you can attach
  handlers for logging, metrics, tracing, or anything else.

  ## Events

  All events follow the `[:adk, <component>, <stage>]` convention with
  `:start`, `:stop`, and `:exception` suffixes (compatible with `:telemetry.span/3`).

  ### Agent Events — `[:adk, :agent, ...]`

  * `[:adk, :agent, :start]` — fired when an agent begins execution
    * Measurements: `%{monotonic_time: integer(), system_time: integer()}`
    * Metadata: `%{agent_name: String.t(), session_id: term()}`

  * `[:adk, :agent, :stop]` — fired when an agent completes
    * Measurements: `%{duration: integer(), monotonic_time: integer()}`
    * Metadata: same as start

  * `[:adk, :agent, :exception]` — fired on agent crash
    * Measurements: `%{duration: integer(), monotonic_time: integer()}`
    * Metadata: same as start + `%{kind: atom(), reason: term(), stacktrace: list()}`

  ### LLM Events — `[:adk, :llm, ...]`

  * `[:adk, :llm, :start]` — fired before an LLM call
    * Measurements: `%{monotonic_time: integer(), system_time: integer()}`
    * Metadata: `%{model: String.t(), agent_name: String.t()}`

  * `[:adk, :llm, :stop]` — fired after an LLM call completes
    * Measurements: `%{duration: integer(), monotonic_time: integer()}`
    * Metadata: same as start

  * `[:adk, :llm, :exception]` — fired on LLM call failure
    * Measurements: `%{duration: integer(), monotonic_time: integer()}`
    * Metadata: same as start + `%{kind: atom(), reason: term(), stacktrace: list()}`

  ### Tool Events — `[:adk, :tool, ...]`

  * `[:adk, :tool, :start]` — fired before a tool executes
    * Measurements: `%{monotonic_time: integer(), system_time: integer()}`
    * Metadata: `%{tool_name: String.t(), agent_name: String.t()}`

  * `[:adk, :tool, :stop]` — fired after a tool completes
    * Measurements: `%{duration: integer(), monotonic_time: integer()}`
    * Metadata: same as start

  * `[:adk, :tool, :exception]` — fired on tool crash
    * Measurements: `%{duration: integer(), monotonic_time: integer()}`
    * Metadata: same as start + `%{kind: atom(), reason: term(), stacktrace: list()}`

  ## Attaching Handlers

      :telemetry.attach_many(
        "my-adk-handler",
        ADK.Telemetry.events(),
        &MyHandler.handle_event/4,
        nil
      )

  ## OpenTelemetry Integration

  When the full `:opentelemetry` SDK is loaded, `span/3` will additionally create
  OpenTelemetry spans, bridging `:telemetry` events into distributed traces.
  No configuration needed — it auto-detects.
  """

  @agent_start [:adk, :agent, :start]
  @agent_stop [:adk, :agent, :stop]
  @agent_exception [:adk, :agent, :exception]

  @llm_start [:adk, :llm, :start]
  @llm_stop [:adk, :llm, :stop]
  @llm_exception [:adk, :llm, :exception]

  @tool_start [:adk, :tool, :start]
  @tool_stop [:adk, :tool, :stop]
  @tool_exception [:adk, :tool, :exception]

  @doc "Returns all event names for use with `:telemetry.attach_many/4`."
  @spec events() :: [list(atom())]
  def events do
    [
      @agent_start, @agent_stop, @agent_exception,
      @llm_start, @llm_stop, @llm_exception,
      @tool_start, @tool_stop, @tool_exception
    ]
  end

  @doc """
  Execute `fun` wrapped in a `:telemetry.span/3` call.

  `event_prefix` should be `[:adk, :agent]`, `[:adk, :llm]`, or `[:adk, :tool]`.
  `metadata` is passed through to all events. `fun` must return `{result, extra_measurements}`
  or just `result` (in which case extra measurements default to `%{}`).

  When `opentelemetry_api` is available, an OTel span is also created.
  """
  @spec span(list(atom()), map(), (-> term())) :: term()
  def span(event_prefix, metadata, fun) when is_list(event_prefix) and is_map(metadata) do
    wrapped_fun = fn ->
      case fun.() do
        {:adk_telemetry, actual_result, extra_metadata} when is_map(extra_metadata) ->
          {actual_result, Map.merge(metadata, extra_metadata)}

        actual_result ->
          {actual_result, metadata}
      end
    end

    if otel_loaded?() do
      otel_span(event_prefix, metadata, wrapped_fun)
    else
      telemetry_span(event_prefix, metadata, wrapped_fun)
    end
  end

  defp telemetry_span(event_prefix, metadata, fun) do
    :telemetry.span(event_prefix, metadata, fun)
  end

  defp otel_span(event_prefix, metadata, fun) do
    span_name = Enum.join(event_prefix, ".")
    tracer = :opentelemetry.get_tracer(:adk)

    :otel_tracer.with_span(tracer, span_name, %{attributes: map_to_otel_attrs(metadata)}, fn span_ctx ->
      telemetry_fun = fn ->
        case fun.() do
          {res, stop_metadata} ->
            :otel_span.set_attributes(span_ctx, map_to_otel_attrs(stop_metadata))
            {res, stop_metadata}
        end
      end

      telemetry_span(event_prefix, metadata, telemetry_fun)
    end)
  end

  defp map_to_otel_attrs(map) do
    Map.to_list(map)
    |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) or is_boolean(v) or is_atom(v) or is_list(v) end)
    |> Map.new()
  end

  @doc false
  def otel_loaded? do
    # Only activate when the full OpenTelemetry SDK is loaded (not just the API)
    Application.spec(:opentelemetry) != nil and
      Code.ensure_loaded?(:otel_tracer) and
      function_exported?(:opentelemetry, :get_tracer, 1)
  end
end
