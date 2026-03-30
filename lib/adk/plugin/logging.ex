defmodule ADK.Plugin.Logging do
  @moduledoc """
  A plugin that wraps every run with structured log output.

  ## Configuration

      # Default — logs at :info level, no model/tool/event logging
      ADK.Plugin.register({ADK.Plugin.Logging, []})

      # Debug level with event contents and model/tool logging
      ADK.Plugin.register({ADK.Plugin.Logging,
        level: :debug,
        include_events: true,
        log_model_calls: true,
        log_tool_calls: true
      })

  ## Options

  - `:level` — Logger level (`:info` | `:debug` | `:warning`). Default `:info`.
  - `:include_events` — whether to log each event in `on_event`. Default `false`.
  - `:log_model_calls` — whether to log `before_model`/`after_model`. Default `false`.
  - `:log_tool_calls` — whether to log `before_tool`/`after_tool`. Default `false`.

  ## Behaviour

  - `before_run/2` — logs run start with agent name and invocation ID; records start time.
  - `after_run/3` — logs run end with event count, error count, and elapsed milliseconds.
  - `before_model/2` — logs model call start (when `log_model_calls: true`).
  - `after_model/2` — logs model call result (when `log_model_calls: true`).
  - `before_tool/3` — logs tool call start (when `log_tool_calls: true`).
  - `after_tool/3` — logs tool call result (when `log_tool_calls: true`).
  - `on_event/2` — logs each event (when `include_events: true`).

  ## Implementation note

  The per-model/tool/event hooks are stateless (no plugin state parameter). To bridge
  the run-level configuration into these hooks, `before_run/2` stores the relevant
  settings in the process dictionary under `{ADK.Plugin.Logging, :config}`. This is
  safe because all hooks within a single `Runner.run/5` call execute in the same
  process.
  """

  @behaviour ADK.Plugin

  require Logger

  @pdict_key {__MODULE__, :config}

  @type config :: [
          level: :info | :debug | :warning,
          include_events: boolean(),
          log_model_calls: boolean(),
          log_tool_calls: boolean()
        ]

  @type state :: %{
          level: :info | :debug | :warning,
          include_events: boolean(),
          log_model_calls: boolean(),
          log_tool_calls: boolean(),
          start_times: %{String.t() => integer()}
        }

  @impl true
  def init(config) when is_list(config) do
    {:ok,
     %{
       level: Keyword.get(config, :level, :info),
       include_events: Keyword.get(config, :include_events, false),
       log_model_calls: Keyword.get(config, :log_model_calls, false),
       log_tool_calls: Keyword.get(config, :log_tool_calls, false),
       start_times: %{}
     }}
  end

  def init(config) when is_map(config) do
    {:ok,
     %{
       level: Map.get(config, :level, :info),
       include_events: Map.get(config, :include_events, false),
       log_model_calls: Map.get(config, :log_model_calls, false),
       log_tool_calls: Map.get(config, :log_tool_calls, false),
       start_times: %{}
     }}
  end

  def init(_), do: init([])

  @impl true
  def before_run(context, state) do
    agent_id = get_agent_id(context)
    invocation_id = context.invocation_id || "unknown"
    now = System.monotonic_time(:millisecond)

    log(
      state.level,
      "[ADK.Plugin.Logging] run start agent=#{agent_id} invocation=#{invocation_id}"
    )

    # Store config in process dict so stateless model/tool/event hooks can access it.
    # This is safe because all hooks in a Runner.run/5 call execute in the same process.
    Process.put(@pdict_key, %{
      level: state.level,
      log_model_calls: state.log_model_calls,
      log_tool_calls: state.log_tool_calls,
      include_events: state.include_events
    })

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

    # Clean up process dict
    Process.delete(@pdict_key)

    new_state = %{state | start_times: Map.delete(state.start_times, invocation_id)}
    {events, new_state}
  end

  @impl true
  def before_model(context, request) do
    with %{log_model_calls: true, level: level} <- Process.get(@pdict_key) do
      agent_id = get_agent_id(context)
      model = Map.get(request, :model, "unknown")
      log(level, "[ADK.Plugin.Logging] model call start agent=#{agent_id} model=#{model}")
    end

    {:ok, request}
  end

  @impl true
  def after_model(context, response) do
    with %{log_model_calls: true, level: level} <- Process.get(@pdict_key) do
      agent_id = get_agent_id(context)
      status = if match?({:ok, _}, response), do: "ok", else: "error"
      log(level, "[ADK.Plugin.Logging] model call end agent=#{agent_id} status=#{status}")
    end

    response
  end

  @impl true
  def before_tool(context, tool_name, args) do
    with %{log_tool_calls: true, level: level} <- Process.get(@pdict_key) do
      agent_id = get_agent_id(context)
      log(level, "[ADK.Plugin.Logging] tool call start agent=#{agent_id} tool=#{tool_name}")
    end

    {:ok, args}
  end

  @impl true
  def after_tool(context, tool_name, result) do
    with %{log_tool_calls: true, level: level} <- Process.get(@pdict_key) do
      agent_id = get_agent_id(context)
      status = if match?({:ok, _}, result), do: "ok", else: "error"

      log(
        level,
        "[ADK.Plugin.Logging] tool call end agent=#{agent_id} tool=#{tool_name} status=#{status}"
      )
    end

    result
  end

  @impl true
  def on_event(context, event) do
    with %{include_events: true, level: level} <- Process.get(@pdict_key) do
      agent_id = get_agent_id(context)

      log(
        level,
        "[ADK.Plugin.Logging] event agent=#{agent_id} id=#{event.id || "nil"} author=#{event.author || "nil"}"
      )
    end

    :ok
  end

  defp get_agent_id(%{agent: %{name: name}}) when is_binary(name), do: name
  defp get_agent_id(_), do: "unknown"

  defp has_error?(%{error: err}) when not is_nil(err), do: true
  defp has_error?(_), do: false

  defp log(:debug, msg), do: Logger.debug(msg)
  defp log(:warning, msg), do: Logger.warning(msg)
  defp log(_, msg), do: Logger.info(msg)
end
