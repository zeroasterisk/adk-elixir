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
    :global_instruction,
    :output_key,
    :context_compressor,
    :output_schema,
    description: "",
    tools: [],
    sub_agents: [],
    max_iterations: 10,
    generate_config: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          model: String.t(),
          instruction: String.t(),
          global_instruction: String.t() | nil,
          output_key: atom() | String.t() | nil,
          context_compressor: keyword() | nil,
          output_schema: map() | nil,
          description: String.t(),
          tools: [map()],
          sub_agents: [ADK.Agent.t()],
          max_iterations: pos_integer(),
          generate_config: map()
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

            # Check if any tool result is a transfer
            transfer = Enum.find(tool_results, &Map.get(&1, :transfer_to_agent))

            case transfer do
              %{transfer_to_agent: target_name} ->
                # Find the target sub-agent
                target = Enum.find(agent.sub_agents, fn sa ->
                  ADK.Agent.name(sa) == target_name
                end)

                transfer_event =
                  ADK.Event.new(%{
                    invocation_id: ctx.invocation_id,
                    author: agent.name,
                    content: %{parts: [%{text: "Transferring to #{target_name}"}]},
                    actions: %ADK.EventActions{transfer_to_agent: target_name}
                  })

                if ctx.session_pid do
                  ADK.Session.append_event(ctx.session_pid, event)
                  ADK.Session.append_event(ctx.session_pid, transfer_event)
                end

                if target do
                  child_ctx = ADK.Context.for_child(ctx, target)
                  sub_events = ADK.Agent.run(target, child_ctx)
                  [event, transfer_event | sub_events]
                else
                  error_event = ADK.Event.error(
                    "Unknown agent: #{target_name}",
                    %{invocation_id: ctx.invocation_id, author: agent.name}
                  )
                  [event, transfer_event, error_event]
                end

              nil ->
                response_parts =
                  Enum.map(tool_results, fn tr ->
                    %{function_response: %{
                      name: tr.name,
                      id: tr[:id],
                      response: tr[:result] || tr[:error] || ""
                    }}
                  end)

                response_event =
                  ADK.Event.new(%{
                    invocation_id: ctx.invocation_id,
                    author: agent.name,
                    content: %{role: :user, parts: response_parts}
                  })

                if ctx.session_pid do
                  ADK.Session.append_event(ctx.session_pid, event)
                  ADK.Session.append_event(ctx.session_pid, response_event)
                end

                [event, response_event | do_run(ctx, agent, iteration + 1)]
            end
        end

      {:error, reason} ->
        case ADK.Callback.run_on_error(ctx.callbacks, {:error, reason}, cb_ctx) do
          {:retry, _retry_ctx} ->
            do_run(ctx, agent, iteration + 1)

          {:fallback, {:ok, response}} ->
            event = event_from_response(response, ctx, agent)
            [event]

          _ ->
            [ADK.Event.error(reason, %{invocation_id: ctx.invocation_id, author: agent.name})]
        end
    end
  end

  defp build_request(ctx, agent) do
    messages = build_messages(ctx)
    all_tools = effective_tools(agent)
    instruction = compile_instruction(ctx, agent)

    # Apply context compression if configured
    compressor_opts =
      case agent.context_compressor do
        nil -> nil
        opts -> Keyword.put_new(opts, :context, %{model: agent.model})
      end

    messages = ADK.Context.Compressor.maybe_compress(messages, compressor_opts)

    request = %{
      model: agent.model,
      instruction: instruction,
      messages: messages,
      tools: Enum.map(all_tools, &ADK.Tool.declaration/1)
    }

    # Merge generate_config: agent defaults + run_config overrides
    merged_config = merge_generate_config(agent.generate_config, ctx)

    case merged_config do
      config when is_map(config) and map_size(config) > 0 ->
        Map.put(request, :generate_config, config)

      _ ->
        request
    end
  end

  defp merge_generate_config(agent_config, %{run_config: %ADK.RunConfig{generate_config: rc}})
       when is_map(rc) and map_size(rc) > 0 do
    case agent_config do
      config when is_map(config) -> Map.merge(config, rc)
      _ -> rc
    end
  end

  defp merge_generate_config(agent_config, _ctx), do: agent_config || %{}

  @doc """
  Compile the full system instruction by merging global + agent instruction
  and substituting state variables via `{key}` template patterns.

  This mirrors Python ADK's `_compile_system_instruction()`.
  """
  @spec compile_instruction(ADK.Context.t(), t()) :: String.t()
  def compile_instruction(ctx, agent) do
    # Merge global + agent instruction
    base =
      case agent.global_instruction do
        nil -> agent.instruction || ""
        "" -> agent.instruction || ""
        global -> global <> "\n" <> (agent.instruction || "")
      end

    # Add transfer instructions if sub-agents exist
    base =
      case agent.sub_agents do
        [] ->
          base

        subs ->
          transfer_info =
            subs
            |> Enum.map(fn sa ->
              name = ADK.Agent.name(sa)
              desc = ADK.Agent.description(sa)

              if desc != "" do
                "- #{name}: #{desc}"
              else
                "- #{name}"
              end
            end)
            |> Enum.join("\n")

          base <>
            "\n\nYou can transfer to these agents:\n" <> transfer_info
      end

    # Substitute state variables
    substitute_state_variables(base, ctx)
  end

  defp substitute_state_variables(text, ctx) do
    state = get_session_state(ctx)

    Regex.replace(~r/\{(\w+)\}/, text, fn full_match, key ->
      try do
        case Map.get(state, key) || Map.get(state, String.to_existing_atom(key)) do
          nil -> full_match
          value -> to_string(value)
        end
      rescue
        ArgumentError -> full_match
      end
    end)
  end

  defp get_session_state(%{session_pid: nil}), do: %{}

  defp get_session_state(%{session_pid: pid}) do
    case ADK.Session.get(pid) do
      {:ok, session} -> session.state
      _ -> %{}
    end
  end

  @doc false
  def effective_tools(agent) do
    transfer_tools =
      case agent.sub_agents do
        [] -> []
        subs -> ADK.Tool.TransferToAgent.tools_for_sub_agents(subs)
      end

    agent.tools ++ transfer_tools
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
      content: response.content
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
      effective_tools(agent)
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

          tool_result =
            case tool_result do
              {:error, _} = err ->
                case ADK.Callback.run_on_tool_error(ctx.callbacks, err, cb_ctx) do
                  {:retry, retry_ctx} ->
                    ADK.Tool.FunctionTool.run(tool, tool_ctx, retry_ctx.tool_args)

                  {:fallback, {:ok, _} = fallback} ->
                    fallback

                  {:error, _} = propagated ->
                    propagated
                end

              other ->
                other
            end

          case tool_result do
            {:transfer_to_agent, target_name} ->
              %{id: call[:id] || "call-1", name: call.name, result: "Transferring to #{target_name}", transfer_to_agent: target_name}

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
