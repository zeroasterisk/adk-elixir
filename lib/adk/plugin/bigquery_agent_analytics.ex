defmodule ADK.Plugin.BigQueryAgentAnalytics do
  @moduledoc """
  A plugin for logging ADK execution events to Google BigQuery.
  """
  @behaviour ADK.Plugin

  require Logger

  @type state :: %{
          project_id: String.t(),
          dataset_id: String.t(),
          table_id: String.t(),
          client: module(),
          max_content_length: integer(),
          log_session_metadata: boolean(),
          custom_tags: map() | nil
        }

  @impl true
  def init(opts) do
    state = %{
      project_id: Keyword.get(opts, :project_id),
      dataset_id: Keyword.get(opts, :dataset_id),
      table_id: Keyword.get(opts, :table_id, "adk_events"),
      client: Keyword.get(opts, :client, __MODULE__.DefaultClient),
      max_content_length: Keyword.get(opts, :max_content_length, 100_000),
      log_session_metadata: Keyword.get(opts, :log_session_metadata, true),
      custom_tags: Keyword.get(opts, :custom_tags, nil)
    }

    if is_nil(state.project_id) or is_nil(state.dataset_id) do
      Logger.warning("BigQueryAgentAnalytics plugin requires project_id and dataset_id")
    end

    Application.put_env(:adk, :bigquery_analytics_plugin_state, state)

    {:ok, state}
  end

  @impl true
  def before_run(context, state) do
    log_event("INVOCATION_STARTING", context, state, nil)
    {:cont, context, state}
  end

  @impl true
  def after_run(result, context, state) do
    log_event("INVOCATION_COMPLETED", context, state, nil)
    {result, state}
  end

  @impl true
  def before_model(context, request) do
    state = get_state()

    content = %{
      prompt: request,
      model: Map.get(context.agent || %{}, :model)
    }

    log_event("LLM_REQUEST", context, state, content)
    {:ok, request}
  end

  @impl true
  def after_model(context, response) do
    state = get_state()

    status =
      case response do
        {:ok, _} -> "OK"
        {:error, _} -> "ERROR"
      end

    log_event("LLM_RESPONSE", context, state, response, status)
    response
  end

  @impl true
  def on_model_error(context, error) do
    state = get_state()
    log_event("LLM_ERROR", context, state, error, "ERROR")
    error
  end

  @impl true
  def before_tool(context, tool_name, args) do
    state = get_state()
    log_event("TOOL_STARTING", context, state, %{tool: tool_name, args: args})
    {:ok, args}
  end

  @impl true
  def after_tool(context, tool_name, result) do
    state = get_state()
    log_event("TOOL_COMPLETED", context, state, %{tool: tool_name, result: result})
    result
  end

  @impl true
  def on_tool_error(context, tool_name, error) do
    state = get_state()
    log_event("TOOL_ERROR", context, state, %{tool: tool_name, error: error}, "ERROR")
    error
  end

  @impl true
  def on_event(context, event) do
    state = get_state()

    case event do
      %{type: :user_message} ->
        log_event("USER_MESSAGE_RECEIVED", context, state, event)

      %{type: :state_delta} ->
        log_event("STATE_DELTA", context, state, event)

      _ ->
        :ok
    end

    :ok
  end

  defp get_state do
    Application.get_env(:adk, :bigquery_analytics_plugin_state, %{
      project_id: "default",
      dataset_id: "default",
      table_id: "adk_events",
      client: __MODULE__.DefaultClient,
      max_content_length: 100_000,
      log_session_metadata: true,
      custom_tags: nil
    })
  end

  defp log_event(event_type, context, state, content, status \\ "OK") do
    {content_json, is_truncated} = encode_content(content, state.max_content_length)

    error_message =
      if status == "ERROR" do
        inspect(content)
      else
        nil
      end

    record = %{
      timestamp: DateTime.utc_now(),
      session_id: session_id(context),
      invocation_id: invocation_id(context),
      event_type: event_type,
      agent: agent_name(context),
      status: status,
      error_message: error_message,
      content: content_json,
      is_truncated: is_truncated,
      attributes: Jason.encode!(enrich_attributes(context, state))
    }

    if client = state[:client] do
      try do
        client.insert(state, record)
      rescue
        e ->
          Logger.error("Failed to log event to BigQuery: #{inspect(e)}")
      end
    end
  end

  defp session_id(%ADK.Context{session_pid: pid}) when is_pid(pid), do: inspect(pid)
  defp session_id(_), do: nil

  defp invocation_id(%ADK.Context{invocation_id: id}), do: id
  defp invocation_id(_), do: nil

  defp agent_name(%ADK.Context{agent: agent}), do: Map.get(agent || %{}, :name)
  defp agent_name(_), do: nil

  defp enrich_attributes(context, state) do
    attrs = %{}

    attrs =
      if state.log_session_metadata && (context.session_pid != nil or context.app_name != nil) do
        Map.put(attrs, :session_metadata, %{
          session_id: session_id(context),
          app_name: context.app_name,
          user_id: context.user_id,
          state: %{}
        })
      else
        attrs
      end

    attrs =
      if state.custom_tags do
        Map.put(attrs, :custom_tags, state.custom_tags)
      else
        attrs
      end

    attrs
  end

  defp encode_content(nil, _max_len), do: {nil, false}

  defp encode_content(content, max_len) do
    content_map =
      case content do
        %{} = map -> map
        other -> %{text_summary: inspect(other)}
      end

    json_str = Jason.encode!(content_map, pretty: false)

    if max_len > 0 and String.length(json_str) > max_len do
      truncated = String.slice(json_str, 0, max_len) <> "...[TRUNCATED]"
      {Jason.encode!(%{truncated: truncated}), true}
    else
      {json_str, false}
    end
  rescue
    _ ->
      str = inspect(content, limit: :infinity)

      if max_len > 0 and String.length(str) > max_len do
        {Jason.encode!(%{truncated: String.slice(str, 0, max_len) <> "...[TRUNCATED]"}), true}
      else
        {Jason.encode!(%{text_summary: str}), false}
      end
  end
end

defmodule ADK.Plugin.BigQueryAgentAnalytics.DefaultClient do
  require Logger

  def insert(_state, record) do
    Logger.debug("BigQuery Event: #{inspect(record)}")
    :ok
  end
end
