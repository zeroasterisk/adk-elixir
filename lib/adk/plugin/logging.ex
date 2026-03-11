defmodule ADK.Plugin.Logging do
  @moduledoc """
  A plugin that wraps every run with structured log output.

  ## Configuration

      # Default — logs at :info level
      ADK.Plugin.register({ADK.Plugin.Logging, []})

      # Debug level with event contents
      ADK.Plugin.register({ADK.Plugin.Logging,
        level: :debug,
        include_events: true
      })

  ## Options

  - `:level` — Logger level (`:info` | `:debug` | `:warning`). Default `:info`.
  - `:include_events` — whether to log event contents in `after_run`. Default `false`
    (only logs event count).

  ## Behaviour

  - `before_run/2` — logs run start with agent name and invocation ID; records start time.
  - `after_run/3` — logs run end with event count, error count, and elapsed milliseconds.
  """

  @behaviour ADK.Plugin

  require Logger

  @type config :: [
          level: :info | :debug | :warning,
          include_events: boolean()
        ]

  @type state :: %{
          level: :info | :debug | :warning,
          include_events: boolean(),
          start_times: %{String.t() => integer()}
        }

  @impl true
  def init(config) when is_list(config) do
    {:ok,
     %{
       level: Keyword.get(config, :level, :info),
       include_events: Keyword.get(config, :include_events, false),
       start_times: %{}
     }}
  end

  def init(config) when is_map(config) do
    {:ok,
     %{
       level: Map.get(config, :level, :info),
       include_events: Map.get(config, :include_events, false),
       start_times: %{}
     }}
  end

  def init(_), do: init([])

  @impl true
  def before_run(context, state) do
    agent_id = get_agent_id(context)
    invocation_id = context.invocation_id || "unknown"
    now = System.monotonic_time(:millisecond)

    log(state.level, "[ADK.Plugin.Logging] run start agent=#{agent_id} invocation=#{invocation_id}")

    new_state = put_in(state.start_times[invocation_id], now)
    {:cont, context, new_state}
  end

  @impl true
  def after_run(events, context, state) do
    agent_id = get_agent_id(context)
    invocation_id = context.invocation_id || "unknown"
    event_count = length(events)
    error_count = Enum.count(events, &has_error?/1)

    elapsed =
      case Map.get(state.start_times, invocation_id) do
        nil -> 0
        start -> System.monotonic_time(:millisecond) - start
      end

    log(
      state.level,
      "[ADK.Plugin.Logging] run end agent=#{agent_id} events=#{event_count} errors=#{error_count} elapsed_ms=#{elapsed}"
    )

    if state.include_events do
      Enum.each(events, fn event ->
        log(state.level, "[ADK.Plugin.Logging] event: #{inspect(event)}")
      end)
    end

    new_state = %{state | start_times: Map.delete(state.start_times, invocation_id)}
    {events, new_state}
  end

  defp get_agent_id(%{agent: %{name: name}}) when is_binary(name), do: name
  defp get_agent_id(_), do: "unknown"

  defp has_error?(%{error: err}) when not is_nil(err), do: true
  defp has_error?(_), do: false

  defp log(:debug, msg), do: Logger.debug(msg)
  defp log(:warning, msg), do: Logger.warning(msg)
  defp log(_, msg), do: Logger.info(msg)
end
