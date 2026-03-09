defmodule ADK.Agent.LlmAgent do
  @moduledoc """
  An LLM-powered agent that can use tools and delegate to sub-agents.

  This is the primary agent type. It calls an LLM, handles tool calls,
  and loops until a final response is produced.
  """

  @enforce_keys [:name, :model, :instruction]
  defstruct [
    :name,
    :model,
    :instruction,
    :output_key,
    :context_compressor,
    description: "",
    tools: [],
    sub_agents: [],
    max_iterations: 10
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          model: String.t(),
          instruction: String.t(),
          output_key: atom() | String.t() | nil,
          context_compressor: keyword() | nil,
          description: String.t(),
          tools: [map()],
          sub_agents: [ADK.Agent.t()],
          max_iterations: pos_integer()
        }

  @doc """
  Create an LLM agent.

  ## Examples

      iex> agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help.")
      iex> agent.name
      "bot"
      iex> is_struct(agent, ADK.Agent.LlmAgent)
      true
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Create an LLM agent with validation.

  Returns `{:ok, agent}` or `{:error, reason}`.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(opts) do
    {:ok, new(opts)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  # --- Protocol implementation ---

  defimpl ADK.Agent do
    def name(agent), do: agent.name
    def description(agent), do: agent.description
    def sub_agents(agent), do: agent.sub_agents
    def run(agent, ctx), do: ADK.Agent.LlmAgent.do_run(ctx, agent, 0)
  end

  # --- Execution ---

  @doc false
  def do_run(_ctx, agent, iteration) when iteration >= agent.max_iterations, do: []

  def do_run(ctx, agent, iteration) do
    request = build_request(ctx, agent)

    cb_ctx = %{agent: ctx.agent, context: ctx, request: request}

    llm_result =
      case ADK.Callback.run_before(ctx.callbacks, :before_model, cb_ctx) do
        {:halt, result} ->
          result

        {:cont, cb_ctx} ->
          result = ADK.LLM.generate(agent.model, cb_ctx.request)
          ADK.Callback.run_after(ctx.callbacks, :after_model, result, cb_ctx)
      end

    case llm_result do
      {:ok, response} ->
        event = event_from_response(response, ctx, agent)

        case extract_function_calls(response) do
          [] ->
            event = maybe_save_output(event, ctx, agent)
            [event]

          calls ->
            tool_results = execute_tools(ctx, agent, calls)

            response_event =
              ADK.Event.new(%{
                invocation_id: ctx.invocation_id,
                author: agent.name,
                function_responses: tool_results
              })

            if ctx.session_pid do
              ADK.Session.append_event(ctx.session_pid, event)
              ADK.Session.append_event(ctx.session_pid, response_event)
            end

            [event, response_event | do_run(ctx, agent, iteration + 1)]
        end

      {:error, reason} ->
        [ADK.Event.error(reason, %{invocation_id: ctx.invocation_id, author: agent.name})]
    end
  end

  defp build_request(ctx, agent) do
    messages = build_messages(ctx)

    # Apply context compression if configured
    compressor_opts =
      case agent.context_compressor do
        nil -> nil
        opts -> Keyword.put_new(opts, :context, %{model: agent.model})
      end

    messages = ADK.Context.Compressor.maybe_compress(messages, compressor_opts)

    %{
      model: agent.model,
      instruction: agent.instruction,
      messages: messages,
      tools: Enum.map(agent.tools, &ADK.Tool.declaration/1)
    }
  end

  defp build_messages(ctx) do
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

  defp event_from_response(response, ctx, agent) do
    ADK.Event.new(%{
      invocation_id: ctx.invocation_id,
      author: agent.name,
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

  defp execute_tools(ctx, agent, calls) do
    tools_map =
      agent.tools
      |> Enum.map(fn t -> {t.name, t} end)
      |> Map.new()

    Enum.map(calls, fn call ->
      case Map.get(tools_map, call.name) do
        nil ->
          %{id: call[:id] || "unknown", name: call.name, error: "Unknown tool: #{call.name}"}

        tool ->
          tool_ctx = ADK.ToolContext.new(ctx, call[:id] || "call-1", tool)
          cb_ctx = %{agent: ctx.agent, context: ctx, tool: tool, tool_args: call.args}

          tool_result =
            ADK.Telemetry.span([:adk, :tool], %{tool_name: call.name, agent_name: ADK.Agent.name(ctx.agent)}, fn ->
              # Check policy authorization first
              case ADK.Policy.check_tool_authorization(ctx.policies, tool, call.args || %{}, ctx) do
                {:deny, reason} ->
                  {:error, "Policy denied tool '#{call.name}': #{reason}"}

                :allow ->
                  case ADK.Callback.run_before(ctx.callbacks, :before_tool, cb_ctx) do
                    {:halt, result} ->
                      result

                    {:cont, cb_ctx} ->
                      result = ADK.Tool.FunctionTool.run(tool, tool_ctx, cb_ctx.tool_args)
                      ADK.Callback.run_after(ctx.callbacks, :after_tool, result, cb_ctx)
                  end
              end
            end)

          case tool_result do
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

  defp maybe_save_output(event, _ctx, _agent), do: event
end
