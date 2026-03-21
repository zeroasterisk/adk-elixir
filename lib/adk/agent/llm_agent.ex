defmodule ADK.Agent.LlmAgent do
  @moduledoc """
  An LLM-powered agent that calls a language model to generate responses,
  handles tool calls, and loops until a final text response is produced.

  This is the primary agent type in ADK Elixir.
  """

  defstruct [
    :name,
    :model,
    :instruction,
    :global_instruction,
    :output_key,
    :output_schema,
    :parent_agent,
    :planner,
    :context_compressor,
    description: "",
    tools: [],
    sub_agents: [],
    _peer_agents: [],
    max_iterations: 10,
    generate_config: %{},
    disallow_transfer_to_parent: false,
    disallow_transfer_to_peers: false
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          model: String.t(),
          instruction: String.t() | (map() -> String.t()),
          global_instruction: String.t() | nil,
          output_key: atom() | String.t() | nil,
          output_schema: map() | nil,
          parent_agent: t() | nil,
          planner: struct() | nil,
          context_compressor: keyword() | nil,
          description: String.t(),
          tools: [map()],
          sub_agents: [map()],
          max_iterations: pos_integer(),
          generate_config: map(),
          disallow_transfer_to_parent: boolean(),
          disallow_transfer_to_peers: boolean()
        }

  def new(opts) do
    agent = struct!(__MODULE__, opts)
    wire_parent(agent)
  end

  defp wire_parent(%__MODULE__{sub_agents: []} = agent), do: agent
  defp wire_parent(%__MODULE__{sub_agents: subs} = agent) when is_list(subs) do
    # Create a minimal parent reference (no sub_agents to avoid circularity)
    parent_ref = %__MODULE__{name: agent.name, model: agent.model, instruction: agent.instruction,
                             description: agent.description}

    # First pass: recursively wire children
    wired_subs = Enum.map(subs, fn
      %__MODULE__{} = child ->
        %{child | parent_agent: parent_ref}
        |> wire_parent()
      other -> other
    end)

    # Second pass: set peer agents (siblings excluding self)
    wired_subs = Enum.map(wired_subs, fn
      %__MODULE__{} = child ->
        peers = Enum.filter(wired_subs, fn
          %__MODULE__{name: n} -> n != child.name
          _ -> false
        end)
        %{child | _peer_agents: peers}
      other -> other
    end)

    %{agent | sub_agents: wired_subs}
  end
  defp wire_parent(agent), do: agent

  # ---------- Protocol Implementation ----------

  defimpl ADK.Agent do
    def name(agent), do: agent.name
    def description(agent), do: agent.description || ""
    def sub_agents(agent), do: agent.sub_agents

    def run(agent, ctx) do
      ADK.Agent.LlmAgent.do_run(ctx, agent, 0)
    end
  end

  # ---------- Real Execution Pipeline ----------

  @doc false
  def do_run(_ctx, agent, iteration) when iteration >= agent.max_iterations, do: []

  def do_run(ctx, agent, iteration) do
    # Build LLM request
    request = build_request(ctx, agent)

    # Run before_model callbacks
    callbacks = ctx.callbacks || []
    cb_ctx = %{agent: agent, context: ctx, request: request}
    case ADK.Callback.run_before(callbacks, :before_model, cb_ctx) do
      {:halt, {:ok, response}} ->
        event = event_from_response(response, ctx, agent)
        event = maybe_save_output_to_state(event, agent)
        if ctx.session_pid, do: ADK.Session.append_event(ctx.session_pid, event)
        ADK.Context.emit_event(ctx, event)
        [event]

      {:halt, {:error, reason}} ->
        error_event = ADK.Event.error(reason, invocation_id: ctx.invocation_id, author: agent.name)
        ADK.Context.emit_event(ctx, error_event)
        [error_event]

      {:cont, _cb_ctx} ->
    # Call the LLM
    case ADK.LLM.generate(agent.model, request) do
      {:ok, %{content: nil}} ->
        # Empty/nil content response — emit nothing (filtered out)
        []

      {:ok, %{partial: true} = response} ->
        # Partial (streaming chunk) response — emit and break the loop
        event = event_from_response(response, ctx, agent)
        ADK.Context.emit_event(ctx, event)
        [event]

      {:ok, raw_response} ->
        # Run after_model callbacks (can modify response)
        after_cb_ctx = %{agent: agent, context: ctx}
        response = ADK.Callback.run_after(callbacks, :after_model, {:ok, raw_response}, after_cb_ctx)
        response = case response do
          {:ok, r} -> r
          other -> other
        end
        event = event_from_response(response, ctx, agent)

        case extract_function_calls(response) do
          [] ->
            # No tool calls — this is the final response
            event = maybe_save_output_to_state(event, agent)
            if ctx.session_pid, do: ADK.Session.append_event(ctx.session_pid, event)
            ADK.Context.emit_event(ctx, event)
            [event]

          calls ->
            # Tool calls — execute them and loop
            ADK.Context.emit_event(ctx, event)
            tool_results = execute_tools(ctx, agent, calls)

            # Check for exit_loop, transfer, or normal continuation
            exit_loop = Enum.find(tool_results, &Map.get(&1, :exit_loop))
            transfer = Enum.find(tool_results, &Map.get(&1, :transfer_to_agent))

            cond do
              exit_loop ->
                exit_reason = exit_loop[:result] || "Exiting loop"
                escalate_event = ADK.Event.new(%{
                  invocation_id: ctx.invocation_id,
                  author: agent.name,
                  content: %{role: :model, parts: [%{text: exit_reason}]},
                  actions: %ADK.EventActions{escalate: true}
                })
                ADK.Context.emit_event(ctx, escalate_event)
                [event, escalate_event]

              transfer ->
              target_name = transfer.transfer_to_agent

              transfer_event =
                ADK.Event.new(%{
                  invocation_id: ctx.invocation_id,
                  author: agent.name,
                  content: %{role: :model, parts: [%{text: "Transferring to #{target_name}"}]},
                  actions: %ADK.EventActions{transfer_to_agent: target_name}
                })

              ADK.Context.emit_event(ctx, transfer_event)

              # Execute the target agent within the same invocation
              target_events =
                case find_transfer_target(agent, target_name) do
                  nil -> []
                  target_agent ->
                    target_ctx = %{ctx | agent: target_agent}
                    do_run(target_ctx, target_agent, 0)
                end

              [event, transfer_event | target_events]

              true ->
              # Build tool response and loop
              response_parts =
                Enum.map(tool_results, fn tr ->
                  %{
                    function_response: %{
                      name: tr.name,
                      response: wrap_tool_response(tr[:result] || tr[:error] || "")
                    }
                  }
                end)

              response_event =
                ADK.Event.new(%{
                  invocation_id: ctx.invocation_id,
                  author: agent.name,
                  content: %{role: :user, parts: response_parts}
                })

              ADK.Context.emit_event(ctx, response_event)

              if ctx.session_pid do
                ADK.Session.append_event(ctx.session_pid, event)
                ADK.Session.append_event(ctx.session_pid, response_event)
              end

              [event, response_event | do_run(ctx, agent, iteration + 1)]
            end # cond
        end

      {:error, reason} ->
        # Run on_model_error callbacks
        cb_ctx_err = %{agent: agent, context: ctx}
        case ADK.Callback.run_on_error(callbacks, {:error, reason}, cb_ctx_err) do
          {:retry, _new_cb_ctx} ->
            do_run(ctx, agent, iteration + 1)

          {:fallback, {:ok, response}} ->
            event = event_from_response(response, ctx, agent)
            event = maybe_save_output_to_state(event, agent)
            if ctx.session_pid, do: ADK.Session.append_event(ctx.session_pid, event)
            ADK.Context.emit_event(ctx, event)
            [event]

          {:error, final_reason} ->
            error_event =
              ADK.Event.new(%{
                invocation_id: ctx.invocation_id,
                author: agent.name,
                content: %{role: :model, parts: [%{text: "Error: #{inspect(final_reason)}"}]},
                error: final_reason
              })

            if ctx.session_pid, do: ADK.Session.append_event(ctx.session_pid, error_event)
            ADK.Context.emit_event(ctx, error_event)
            [error_event]
        end
    end  # end LLM generate case
    end  # end before_model callback case
  end

  @doc """
  Build the LLM request from the current context and agent config.
  """
  def build_request(ctx, agent) do
    instruction = compile_instruction(ctx, agent)
    messages = build_messages(ctx)
    all_tools = effective_tools(agent)

    request = %{
      model: agent.model,
      instruction: instruction,
      messages: messages,
      tools: Enum.map(all_tools, &ADK.Tool.declaration/1),
      agent_name: agent.name
    }

    case agent.generate_config do
      config when is_map(config) and map_size(config) > 0 ->
        Map.put(request, :generate_config, config)

      _ ->
        request
    end
  end

  @doc """
  Compile the instruction string, merging global + agent instruction
  and substituting `{key}` state variables.
  """
  def compile_instruction(ctx, agent) do
    base = resolve_instruction(agent.instruction, ctx)

    base =
      case agent.global_instruction do
        nil ->
          base

        "" ->
          base

        global ->
          resolved_global = resolve_instruction(global, ctx)
          resolved_global <> "\n" <> base
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
              if desc != "", do: "- #{name}: #{desc}", else: "- #{name}"
            end)
            |> Enum.join("\n")

          base <> "\n\nYou can transfer to these agents:\n" <> transfer_info
      end

    # Substitute {key} state variables from session
    substitute_state_variables(base, ctx)
  end

  @doc """
  Compute the full tool list including auto-generated transfer tools.
  """
  def effective_tools(agent) do
    targets = transfer_targets(agent)
    transfer_tools =
      case targets do
        [] -> []
        agents -> ADK.Tool.TransferToAgent.tools_for_sub_agents(agents)
      end

    agent.tools ++ transfer_tools
  end

  @doc false
  def find_transfer_target(agent, target_name) do
    # Check sub-agents
    result = Enum.find(agent.sub_agents || [], fn a ->
      is_struct(a) && Map.get(a, :name) == target_name
    end)

    if result do
      result
    else
      # Check parent
      parent = agent.parent_agent
      if parent && is_struct(parent) && Map.get(parent, :name) == target_name do
        parent
      else
        # Check peer agents
        Enum.find(agent._peer_agents || [], fn a ->
          is_struct(a) && Map.get(a, :name) == target_name
        end)
      end
    end
  end

  @doc """
  Compute the list of agents this agent can transfer to.

  Includes sub-agents, parent (if not disallowed), and peer siblings (if not disallowed).
  """
  def transfer_targets(agent) do
    subs = agent.sub_agents || []

    parent =
      if agent.parent_agent && !agent.disallow_transfer_to_parent do
        [agent.parent_agent]
      else
        []
      end

    peers =
      if !agent.disallow_transfer_to_peers do
        agent._peer_agents || []
      else
        []
      end

    subs ++ parent ++ peers
  end

  @doc """
  Get all agent names in the agent tree for error reporting.
  """
  def get_available_agent_names(%__MODULE__{} = root_agent) do
    collect_agent_names(root_agent, [])
  end

  @doc """
  Find an agent by name in the tree, or raise with a helpful error.
  """
  def get_agent_to_run(%__MODULE__{} = root_agent, agent_name) do
    case find_agent(root_agent, agent_name) do
      nil ->
        available = get_available_agent_names(root_agent)

        raise ArgumentError, """
        Agent '#{agent_name}' not found.
        Available agents: #{Enum.join(available, ", ")}
        """

      agent ->
        {:ok, agent}
    end
  end

  @doc """
  Clone an agent with optional overrides.
  """
  def clone(%__MODULE__{} = agent, overrides \\ %{}) do
    agent
    |> Map.from_struct()
    |> Map.merge(overrides)
    |> then(&struct!(__MODULE__, &1))
  end

  # ---------- Private Helpers ----------

  defp resolve_instruction(instruction, ctx) when is_function(instruction, 1),
    do: instruction.(ctx)

  defp resolve_instruction({mod, fun}, ctx), do: apply(mod, fun, [ctx])
  defp resolve_instruction({mod, fun, args}, ctx), do: apply(mod, fun, [ctx | args])
  defp resolve_instruction(instruction, _ctx) when is_binary(instruction), do: instruction
  defp resolve_instruction(nil, _ctx), do: ""

  defp substitute_state_variables(text, %{session_pid: nil}), do: text

  defp substitute_state_variables(text, %{session_pid: pid}) do
    state =
      case ADK.Session.get(pid) do
        {:ok, session} -> session.state
        _ -> %{}
      end

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

  defp substitute_state_variables(text, _ctx), do: text

  defp build_messages(ctx) do
    history =
      if ctx.session_pid do
        ADK.Session.get_events(ctx.session_pid)
        |> Enum.map(fn e ->
          if e.author == "user" do
            %{role: :user, parts: (e.content || %{})[:parts] || []}
          else
            %{role: :model, parts: (e.content || %{})[:parts] || []}
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

  @doc false
  def maybe_save_output_to_state(event, agent) do
    output_key = agent.output_key

    cond do
      is_nil(output_key) ->
        event

      event.partial == true ->
        event

      event.author != agent.name ->
        require Logger
        Logger.debug("Skipping output save for agent #{agent.name}: event authored by #{event.author}")
        event

      true ->
        text = extract_text_from_event_content(event.content)

        if is_nil(text) or String.trim(text) == "" do
          event
        else
          value = maybe_parse_with_schema(text, agent.output_schema)
          delta = %{added: Map.put(%{}, output_key, value), changed: %{}, removed: []}
          actions = event.actions || %ADK.EventActions{}
          %{event | actions: %{actions | state_delta: delta}}
        end
    end
  end

  defp extract_text_from_event_content(nil), do: nil

  defp extract_text_from_event_content(content) when is_map(content) do
    parts = Map.get(content, "parts") || Map.get(content, :parts) || []

    texts =
      Enum.flat_map(parts, fn
        %{"text" => t} when is_binary(t) -> [t]
        %{text: t} when is_binary(t) -> [t]
        _ -> []
      end)

    case texts do
      [] -> nil
      list -> Enum.join(list, "")
    end
  end

  defp extract_text_from_event_content(_), do: nil

  defp maybe_parse_with_schema(text, nil), do: text

  defp maybe_parse_with_schema(text, _schema) do
    case Jason.decode(text) do
      {:ok, parsed} -> parsed
      {:error, _} -> text
    end
  end

  defp event_from_response(response, ctx, agent) do
    ADK.Event.new(%{
      invocation_id: ctx.invocation_id,
      author: agent.name,
      branch: ctx.branch,
      content: response.content,
      partial: Map.get(response, :partial)
    })
  end

  defp extract_function_calls(%{content: content}) when is_map(content) do
    parts = Map.get(content, "parts") || Map.get(content, :parts) || []

    Enum.flat_map(parts, fn
      %{"function_call" => fc} -> [fc]
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
          %{name: call.name, error: "Unknown tool: #{call.name}"}

        tool ->
          tool_ctx = ADK.ToolContext.new(ctx, call[:id] || "call-1", tool)
          callbacks = ctx.callbacks || []
          tool_cb_ctx = %{agent: agent, context: ctx, tool: tool, tool_args: call.args || %{}}

          result = case ADK.Callback.run_before(callbacks, :before_tool, tool_cb_ctx) do
            {:halt, halted_result} -> halted_result
            {:cont, _} -> 
              res = run_tool(tool, tool_ctx, call.args || %{})
              case res do
                {:error, reason} ->
                  case ADK.Callback.run_on_tool_error(callbacks, {:error, reason}, tool_cb_ctx) do
                    {:retry, _} -> run_tool(tool, tool_ctx, call.args || %{})
                    {:fallback, fallback_res} -> fallback_res
                    err -> err
                  end
                other -> other
              end
          end

          result = ADK.Callback.run_after(callbacks, :after_tool, result, tool_cb_ctx)

          case result do
            {:transfer_to_agent, target} ->
              %{name: call.name, result: "Transferring to #{target}", transfer_to_agent: target}

            {:exit_loop, reason} ->
              %{name: call.name, result: reason, exit_loop: true}

            {:ok, value} ->
              %{name: call.name, result: value}

            {:error, reason} ->
              %{name: call.name, error: inspect(reason)}
          end
      end
    end)
  end

  defp run_tool(%ADK.Tool.ModuleTool{} = tool, ctx, args),
    do: ADK.Tool.ModuleTool.run(tool, ctx, args)

  defp run_tool(%ADK.Tool.FunctionTool{} = tool, ctx, args),
    do: ADK.Tool.FunctionTool.run(tool, ctx, args)

  defp run_tool(%ADK.Tool.LongRunningTool{} = tool, ctx, args),
    do: ADK.Tool.LongRunningTool.run(tool, ctx, args)

  defp run_tool(%ADK.Tool.GoogleSearch{}, _ctx, _args),
    do: {:error, "GoogleSearch is a built-in Gemini tool"}

  defp run_tool(tool, ctx, args), do: ADK.Tool.FunctionTool.run(tool, ctx, args)

  defp wrap_tool_response(response) when is_map(response), do: response
  defp wrap_tool_response(response), do: %{"result" => response}

  defp collect_agent_names(%{name: name, sub_agents: subs}, acc) when is_list(subs) do
    children = Enum.flat_map(subs, &collect_agent_names(&1, []))
    acc ++ [name] ++ children
  end

  defp collect_agent_names(%{name: name}, acc), do: acc ++ [name]

  defp find_agent(%{name: name} = agent, name), do: agent

  defp find_agent(%{sub_agents: subs}, target) when is_list(subs) do
    Enum.find_value(subs, fn sub -> find_agent(sub, target) end)
  end

  defp find_agent(_, _), do: nil
end
