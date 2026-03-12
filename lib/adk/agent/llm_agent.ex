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
    :parent_agent,
    description: "",
    tools: [],
    skills: [],
    sub_agents: [],
    max_iterations: 10,
    generate_config: %{},
    disallow_transfer_to_parent: false,
    disallow_transfer_to_peers: false
  ]

  @typedoc """
  An instruction provider can be:
  - `String.t()` — static instruction string (existing, unchanged)
  - `(ADK.Context.t() -> String.t())` — 1-arity function called at runtime with the context
  - `{module, atom}` — MFA called as `module.atom(ctx)`
  - `{module, atom, [extra_args]}` — MFA called as `module.atom(ctx, extra_args...)`
  """
  @type instruction_provider ::
          String.t()
          | (ADK.Context.t() -> String.t())
          | {module(), atom()}
          | {module(), atom(), list()}

  @type t :: %__MODULE__{
          name: String.t(),
          model: String.t(),
          instruction: instruction_provider(),
          global_instruction: instruction_provider() | nil,
          output_key: atom() | String.t() | nil,
          context_compressor: keyword() | nil,
          output_schema: map() | nil,
          parent_agent: ADK.Agent.t() | nil,
          description: String.t(),
          tools: [map()],
          skills: [ADK.Skill.t()],
          sub_agents: [ADK.Agent.t()],
          max_iterations: pos_integer(),
          generate_config: map(),
          disallow_transfer_to_parent: boolean(),
          disallow_transfer_to_peers: boolean()
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
  def new(opts) do
    skills = Keyword.get(opts, :skills, [])

    opts =
      if skills == [] do
        opts
      else
        ADK.Skill.apply_to_opts(opts, skills)
      end

    agent = struct!(__MODULE__, opts)

    # Wire up parent_agent on sub-agents for bidirectional transfer
    if agent.sub_agents != [] do
      updated_subs =
        Enum.map(agent.sub_agents, fn
          %__MODULE__{} = sub -> %{sub | parent_agent: agent}
          other -> other
        end)

      %{agent | sub_agents: updated_subs}
    else
      agent
    end
  end

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
    # Enforce max_llm_calls from RunConfig (counts LLM invocations across the run)
    if llm_call_limit_reached?(ctx, iteration) do
      [ADK.Event.error(
        "max_llm_calls limit reached",
        %{invocation_id: ctx.invocation_id, author: agent.name}
      )]
    else
      do_run_inner(ctx, agent, iteration)
    end
  end

  defp llm_call_limit_reached?(%{run_config: %ADK.RunConfig{max_llm_calls: max}}, iteration)
       when is_integer(max) and max >= 1 do
    iteration >= max
  end

  defp llm_call_limit_reached?(_ctx, _iteration), do: false

  defp do_run_inner(ctx, agent, iteration) do
    request = build_request(ctx, agent)

    cb_ctx = %{agent: ctx.agent, context: ctx, request: request}

    llm_result =
      case ADK.Callback.run_before(ctx.callbacks, :before_model, cb_ctx) do
        {:halt, result} ->
          result

        {:cont, cb_ctx} ->
          # Run plugin before_model hooks (can modify request or skip model call)
          case ADK.Plugin.run_before_model(ctx.plugins, ctx, cb_ctx.request) do
            {:skip, response} ->
              response

            {:ok, new_request} ->
              cb_ctx = %{cb_ctx | request: new_request}
              result = ADK.LLM.generate(agent.model, cb_ctx.request)
              result = ADK.Callback.run_after(ctx.callbacks, :after_model, result, cb_ctx)
              # Run plugin after_model hooks (can transform response)
              ADK.Plugin.run_after_model(ctx.plugins, ctx, result)
          end
      end

    case llm_result do
      {:ok, response} ->
        event = event_from_response(response, ctx, agent)

        case extract_function_calls(response) do
          [] ->
            event = maybe_save_output(event, ctx, agent)
            # Emit final response event via streaming callback
            ADK.Context.emit_event(ctx, event)
            [event]

          calls ->
            # Emit the model event (with tool calls) immediately for streaming
            ADK.Context.emit_event(ctx, event)
            tool_results = execute_tools(ctx, agent, calls)

            # Check signal priority: exit_loop > transfer_to_agent > normal
            exit_loop = Enum.find(tool_results, &Map.get(&1, :exit_loop))
            transfer = Enum.find(tool_results, &Map.get(&1, :transfer_to_agent))

            cond do
              exit_loop ->
                # LLM called exit_loop — emit an escalation event to break out of LoopAgent
                exit_reason = exit_loop[:result] || "Exiting loop"

                escalate_event =
                  ADK.Event.new(%{
                    invocation_id: ctx.invocation_id,
                    author: agent.name,
                    branch: ctx.branch,
                    content: %{parts: [%{text: exit_reason}]},
                    actions: %ADK.EventActions{escalate: true}
                  })

                ADK.Context.emit_event(ctx, escalate_event)

                if ctx.session_pid do
                  ADK.Session.append_event(ctx.session_pid, event)
                  ADK.Session.append_event(ctx.session_pid, escalate_event)
                end

                [event, escalate_event]

              transfer ->
                # Find the target agent (sub-agent, parent, or peer)
                target_name = transfer.transfer_to_agent

                target = Enum.find(transfer_targets(agent), fn sa ->
                  ADK.Agent.name(sa) == target_name
                end)

                transfer_event =
                  ADK.Event.new(%{
                    invocation_id: ctx.invocation_id,
                    author: agent.name,
                    branch: ctx.branch,
                    content: %{parts: [%{text: "Transferring to #{target_name}"}]},
                    actions: %ADK.EventActions{transfer_to_agent: target_name}
                  })

                ADK.Context.emit_event(ctx, transfer_event)

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
                  ADK.Context.emit_event(ctx, error_event)
                  [event, transfer_event, error_event]
                end

              true ->
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
                    branch: ctx.branch,
                    content: %{role: :user, parts: response_parts}
                  })

                ADK.Context.emit_event(ctx, response_event)

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
            ADK.Context.emit_event(ctx, event)
            [event]

          _ ->
            error_event = ADK.Event.error(reason, %{invocation_id: ctx.invocation_id, author: agent.name})
            ADK.Context.emit_event(ctx, error_event)
            [error_event]
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
        nil ->
          nil

        opts ->
          opts
          |> Keyword.put_new(:context, %{model: agent.model})
          |> Keyword.put_new(:session_pid, ctx.session_pid)
      end

    messages = ADK.Context.Compressor.maybe_compress(messages, compressor_opts)

    # Split instructions for context caching support
    {static_instruction, dynamic_instruction} =
      ADK.InstructionCompiler.compile_split(agent, ctx)

    request = %{
      model: agent.model,
      instruction: instruction,
      static_system_instruction: static_instruction,
      dynamic_system_instruction: dynamic_instruction,
      messages: messages,
      tools: Enum.map(all_tools, &ADK.Tool.declaration/1)
    }

    # Merge generate_config: agent defaults + run_config overrides
    merged_config = merge_generate_config(agent.generate_config, ctx)

    request =
      case merged_config do
        config when is_map(config) and map_size(config) > 0 ->
          Map.put(request, :generate_config, config)

        _ ->
          request
      end

    # Apply RunConfig passthrough fields
    apply_run_config_to_request(request, ctx)
  end

  defp apply_run_config_to_request(request, %{run_config: %ADK.RunConfig{} = rc}) do
    request
    |> maybe_put(:output_config, rc.output_config)
    |> maybe_put(:response_modalities, rc.response_modalities)
    |> maybe_put(:speech_config, rc.speech_config)
  end

  defp apply_run_config_to_request(request, _ctx), do: request

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  @doc """
  Compute the full tool list including auto-generated transfer tools.

  Transfer targets include:
  - Sub-agents (always, unless empty)
  - Parent agent (unless `disallow_transfer_to_parent` is true)
  - Peer agents (siblings under same parent, unless `disallow_transfer_to_peers` is true)

  This mirrors Python ADK's bidirectional transfer support.
  """
  @spec effective_tools(t()) :: [map()]
  def effective_tools(agent) do
    targets = transfer_targets(agent)

    transfer_tools =
      if targets == [] do
        []
      else
        ADK.Tool.TransferToAgent.tools_for_sub_agents(targets)
      end

    agent.tools ++ transfer_tools
  end

  @doc """
  Compute the list of agents this agent can transfer to.

  Includes sub-agents, optionally parent and peer agents.
  """
  @spec transfer_targets(t()) :: [ADK.Agent.t()]
  def transfer_targets(agent) do
    sub_targets = agent.sub_agents || []

    parent_targets =
      if agent.parent_agent && !agent.disallow_transfer_to_parent do
        [agent.parent_agent]
      else
        []
      end

    peer_targets =
      if agent.parent_agent && !agent.disallow_transfer_to_peers do
        parent = agent.parent_agent
        siblings = Map.get(parent, :sub_agents, [])
        Enum.reject(siblings, fn sa -> ADK.Agent.name(sa) == agent.name end)
      else
        []
      end

    sub_targets ++ parent_targets ++ peer_targets
  end

  defp build_messages(ctx) do
    current_branch = ctx.branch
    current_agent = ADK.Agent.name(ctx.agent)

    history =
      if ctx.session_pid do
        ADK.Session.get_events(ctx.session_pid)
        |> Enum.filter(&ADK.Event.on_branch?(&1, current_branch))
        |> Enum.map(fn e ->
          cond do
            # Compaction events are always user-role summaries
            ADK.Event.compaction?(e) ->
              %{role: :user, parts: (e.content || %{})[:parts] || []}

            # User messages stay as-is
            e.author == "user" ->
              %{role: :user, parts: (e.content || %{})[:parts] || []}

            # Messages from the current agent stay as model messages
            e.author == current_agent ->
              %{role: :model, parts: (e.content || %{})[:parts] || []}

            # Messages from other agents are reformatted as user-role context
            true ->
              reformat_other_agent_message(e)
          end
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

  # Feature 5: Other-Agent Message Reformatting
  # Rewrites messages from other agents as "[agent_name] said: ..." in user role,
  # mirroring Python ADK's content assembly behavior.
  defp reformat_other_agent_message(event) do
    agent_name = event.author || "unknown"
    parts = (event.content || %{})[:parts] || []

    reformatted_parts =
      Enum.flat_map(parts, fn
        %{text: text} when is_binary(text) ->
          [%{text: "[#{agent_name}] said: #{text}"}]

        %{function_call: %{name: fname, args: args}} ->
          args_str = if is_map(args), do: Jason.encode!(args), else: inspect(args)
          [%{text: "[#{agent_name}] called tool `#{fname}` with parameters: #{args_str}"}]

        %{function_response: %{name: fname, response: resp}} ->
          resp_str = if is_binary(resp), do: resp, else: inspect(resp)
          [%{text: "[#{agent_name}] tool `#{fname}` returned: #{resp_str}"}]

        other ->
          [other]
      end)

    %{role: :user, parts: reformatted_parts}
  end

  defp event_from_response(response, ctx, agent) do
    ADK.Event.new(%{
      invocation_id: ctx.invocation_id,
      author: agent.name,
      branch: ctx.branch,
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
                      # Run plugin before_tool hooks (can modify args or skip tool)
                      case ADK.Plugin.run_before_tool(ctx.plugins, ctx, call.name, cb_ctx.tool_args) do
                        {:skip, result} ->
                          result

                        {:ok, new_args} ->
                          cb_ctx = %{cb_ctx | tool_args: new_args}
                          result = run_tool(tool, tool_ctx, cb_ctx.tool_args)
                          result = ADK.Callback.run_after(ctx.callbacks, :after_tool, result, cb_ctx)
                          # Run plugin after_tool hooks (can transform result)
                          ADK.Plugin.run_after_tool(ctx.plugins, ctx, call.name, result)
                      end
                  end
              end
            end)

          tool_result =
            case tool_result do
              {:error, _} = err ->
                case ADK.Callback.run_on_tool_error(ctx.callbacks, err, cb_ctx) do
                  {:retry, retry_ctx} ->
                    run_tool(tool, tool_ctx, retry_ctx.tool_args)

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

            {:exit_loop, reason} ->
              %{id: call[:id] || "call-1", name: call.name, result: reason, exit_loop: true}

            {:ok, result} ->
              %{id: call[:id] || "call-1", name: call.name, result: result}

            {:error, reason} ->
              %{id: call[:id] || "call-1", name: call.name, error: inspect(reason)}
          end
      end
    end)
  end

  defp run_tool(%ADK.Tool.ModuleTool{} = tool, ctx, args), do: ADK.Tool.ModuleTool.run(tool, ctx, args)
  defp run_tool(%ADK.Tool.FunctionTool{} = tool, ctx, args), do: ADK.Tool.FunctionTool.run(tool, ctx, args)
  defp run_tool(%ADK.Tool.LongRunningTool{} = tool, ctx, args), do: ADK.Tool.LongRunningTool.run(tool, ctx, args)
  defp run_tool(%ADK.Tool.GoogleSearch{}, ctx, args), do: ADK.Tool.GoogleSearch.run(ctx, args)
  defp run_tool(%ADK.Tool.BuiltInCodeExecution{}, ctx, args), do: ADK.Tool.BuiltInCodeExecution.run(ctx, args)
  defp run_tool(tool, ctx, args), do: ADK.Tool.FunctionTool.run(tool, ctx, args)

  defp maybe_save_output(event, ctx, %{output_key: key}) when not is_nil(key) do
    text = ADK.Event.text(event)

    if text && ctx.session_pid do
      ADK.Session.put_state(ctx.session_pid, key, text)
    end

    event
  end

  defp maybe_save_output(event, _ctx, _agent), do: event
end
