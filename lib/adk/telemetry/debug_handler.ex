defmodule ADK.Telemetry.DebugHandler do
  @moduledoc """
  Telemetry handler that captures ADK events into `ADK.Telemetry.SpanStore`.

  Attaches to all `ADK.Telemetry.events()` `:stop` events and builds span-like
  maps that are stored by event_id and session_id for the debug/trace HTTP endpoints.

  ## Usage

  Called automatically during application startup. Can also be attached manually:

      ADK.Telemetry.DebugHandler.attach()

  ## Span Format

  Each captured span is a map with:

      %{
        name: "adk.agent.stop",
        span_id: "a1b2c3...",
        trace_id: "d4e5f6...",
        start_time: 1710000000.0,
        end_time: 1710000001.5,
        duration_ms: 1500.0,
        attributes: %{agent_name: "my_agent", session_id: "sess-1", ...}
      }
  """

  @handler_id "adk-debug-span-collector"

  @doc "Attach the debug handler to all ADK telemetry stop events."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    stop_events =
      ADK.Telemetry.events()
      |> Enum.filter(fn event -> List.last(event) == :stop end)

    :telemetry.attach_many(
      @handler_id,
      stop_events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc "Detach the debug handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    span = build_span(event, measurements, metadata)
    event_id = metadata[:event_id] || span.span_id
    session_id = metadata[:session_id]

    # Always store by event_id
    if is_binary(event_id) do
      ADK.Telemetry.SpanStore.put_event_span(event_id, span.attributes)
    end

    # Store full span by session_id if available
    if is_binary(session_id) do
      ADK.Telemetry.SpanStore.put_session_span(session_id, span)
    end
  rescue
    # Never crash the caller — silently drop on error
    _ -> :ok
  end

  defp build_span(event, measurements, metadata) do
    now = System.system_time(:microsecond)
    duration_ns = measurements[:duration] || 0
    duration_ms = duration_ns / 1_000_000

    end_time = now / 1_000_000
    start_time = end_time - duration_ms / 1_000

    attributes =
      metadata
      |> Map.drop([:kind, :reason, :stacktrace])
      |> Map.new(fn {k, v} -> {to_string(k), serialize_value(v)} end)

    %{
      name: Enum.join(event, "."),
      span_id: random_hex(8),
      trace_id: random_hex(16),
      start_time: start_time,
      end_time: end_time,
      duration_ms: Float.round(duration_ms, 3),
      attributes: attributes
    }
  end

  defp serialize_value(v) when is_binary(v), do: v
  defp serialize_value(v) when is_number(v), do: v
  defp serialize_value(v) when is_boolean(v), do: v
  defp serialize_value(v) when is_atom(v), do: to_string(v)
  defp serialize_value(v), do: inspect(v)

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end
end
