defmodule ADK.Telemetry.DefaultHandler do
  @moduledoc """
  A simple Logger-based telemetry handler for development.

  Attaches to all ADK telemetry events and logs them at `:debug` level
  with timing information. Useful during development to see what's
  happening in the ADK pipeline.

  ## Quick Start

      ADK.Telemetry.DefaultHandler.attach()

  ## What Gets Logged

  Start events log the event name and metadata:

      [debug] [ADK] [:adk, :runner, :start] app_name=myapp agent_name=bot session_id=s1

  Stop events include duration:

      [debug] [ADK] [:adk, :runner, :stop] duration=42.5ms app_name=myapp agent_name=bot

  Exception events include error details:

      [debug] [ADK] [:adk, :llm, :exception] kind=error reason=%RuntimeError{message: "boom"} duration=1.2ms

  ## Detaching

      ADK.Telemetry.DefaultHandler.detach()
  """

  require Logger

  @handler_id "adk-default-logger-handler"

  @doc """
  Attach the default Logger handler to all ADK telemetry events.

  Returns `:ok` on success, `{:error, :already_exists}` if already attached.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(
      @handler_id,
      ADK.Telemetry.Contract.all_events(),
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc """
  Detach the default Logger handler.
  """
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    suffix = List.last(event)
    event_str = inspect(event)

    case suffix do
      :start ->
        Logger.debug(fn ->
          "[ADK] #{event_str} #{format_metadata(metadata)}"
        end)

      :stop ->
        duration_ms = format_duration(measurements[:duration])

        Logger.debug(fn ->
          "[ADK] #{event_str} duration=#{duration_ms} #{format_metadata(metadata)}"
        end)

      :exception ->
        duration_ms = format_duration(measurements[:duration])
        kind = metadata[:kind]
        reason = metadata[:reason]

        Logger.debug(fn ->
          "[ADK] #{event_str} kind=#{kind} reason=#{inspect(reason)} duration=#{duration_ms} #{format_metadata(Map.drop(metadata, [:kind, :reason, :stacktrace]))}"
        end)

      _ ->
        Logger.debug(fn ->
          "[ADK] #{event_str} #{format_metadata(metadata)}"
        end)
    end
  end

  defp format_duration(nil), do: "0ms"

  defp format_duration(duration_ns) when is_integer(duration_ns) do
    ms = duration_ns / 1_000_000
    "#{Float.round(ms, 2)}ms"
  end

  defp format_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop([:kind, :reason, :stacktrace])
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")
  end
end
