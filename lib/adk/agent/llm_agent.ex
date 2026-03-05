defmodule ADK.Agent.LlmAgent do
  @moduledoc """
  An LLM-powered agent that can use tools and delegate to sub-agents.

  This is the primary agent type. It calls an LLM, handles tool calls,
  and loops until a final response is produced.
  """
  @behaviour ADK.Agent

  defstruct [
    :name,
    :description,
    :model,
    :instruction,
    :output_key,
    tools: [],
    sub_agents: [],
    max_iterations: 10
  ]

  @doc """
  Create an LLM agent spec.

  ## Examples

      iex> agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help.")
      iex> agent.name
      "bot"
      iex> agent.module
      ADK.Agent.LlmAgent
  """
  @spec new(keyword()) :: ADK.Agent.t()
  def new(opts) do
    config = struct!(__MODULE__, opts)

    %{
      name: config.name,
      description: config.description || "",
      module: __MODULE__,
      config: config,
      sub_agents: config.sub_agents
    }
  end

  @impl true
  def run(ctx) do
    config = ctx.agent.config
    do_run(ctx, config, 0)
  end

  defp do_run(_ctx, config, iteration) when iteration >= config.max_iterations, do: []

  defp do_run(ctx, config, iteration) do
    # Build LLM request
    request = build_request(ctx, config)

    case ADK.LLM.generate(config.model, request) do
      {:ok, response} ->
        event = event_from_response(response, ctx, config)

        case extract_function_calls(response) do
          [] ->
            # Final response — possibly save to output_key
            event = maybe_save_output(event, ctx, config)
            [event]

          calls ->
            # Execute tools
            tool_results = execute_tools(ctx, config, calls)

            response_event =
              ADK.Event.new(%{
                invocation_id: ctx.invocation_id,
                author: config.name,
                function_responses: tool_results
              })

            # Append tool events to session if available
            if ctx.session_pid do
              ADK.Session.append_event(ctx.session_pid, event)
              ADK.Session.append_event(ctx.session_pid, response_event)
            end

            # Loop for next LLM call
            [event, response_event | do_run(ctx, config, iteration + 1)]
        end

      {:error, reason} ->
        [ADK.Event.error(reason, %{invocation_id: ctx.invocation_id, author: config.name})]
    end
  end

  defp build_request(ctx, config) do
    messages = build_messages(ctx, config)

    %{
      model: config.model,
      instruction: config.instruction,
      messages: messages,
      tools: Enum.map(config.tools, &ADK.Tool.declaration/1)
    }
  end

  defp build_messages(ctx, _config) do
    history =
      if ctx.session_pid do
        ADK.Session.get_events(ctx.session_pid)
        |> Enum.map(fn e ->
          role = if e.author == "user", do: :user, else: :model
          %{role: role, parts: (e.content || %{})[:parts] || []}
        end)
      else
        []
      end

    user_msg =
      case ctx.user_content do
        %{text: text} -> [%{role: :user, parts: [%{text: text}]}]
        nil -> []
        text when is_binary(text) -> [%{role: :user, parts: [%{text: text}]}]
        _ -> []
      end

    history ++ user_msg
  end

  defp event_from_response(response, ctx, config) do
    ADK.Event.new(%{
      invocation_id: ctx.invocation_id,
      author: config.name,
      content: response.content,
      function_calls: extract_function_calls(response)
    })
  end

  defp extract_function_calls(%{content: %{parts: parts}}) when is_list(parts) do
    Enum.flat_map(parts, fn
      %{function_call: fc} -> [fc]
      _ -> []
    end)
  end

  defp extract_function_calls(_), do: []

  defp execute_tools(ctx, config, calls) do
    tools_map =
      config.tools
      |> Enum.map(fn t -> {t.name, t} end)
      |> Map.new()

    Enum.map(calls, fn call ->
      case Map.get(tools_map, call.name) do
        nil ->
          %{id: call[:id] || "unknown", name: call.name, error: "Unknown tool: #{call.name}"}

        tool ->
          tool_ctx = ADK.ToolContext.new(ctx, call[:id] || "call-1", tool)

          case ADK.Tool.FunctionTool.run(tool, tool_ctx, call.args) do
            {:ok, result} ->
              %{id: call[:id] || "call-1", name: call.name, result: result}

            {:error, reason} ->
              %{id: call[:id] || "call-1", name: call.name, error: inspect(reason)}
          end
      end
    end)
  end

  defp maybe_save_output(event, ctx, %{output_key: key}) when not is_nil(key) do
    text = ADK.Event.text(event)

    if text && ctx.session_pid do
      ADK.Session.put_state(ctx.session_pid, key, text)
    end

    event
  end

  defp maybe_save_output(event, _ctx, _config), do: event
end
