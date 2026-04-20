defmodule ADK.Agent.LlmAgent do
  @moduledoc """
  An LLM-powered agent that calls a language model to generate responses,
  handles tool calls, and loops until a final text response is produced.

  This is the primary agent type in ADK Elixir.

  ## Options

  * `:max_history_turns` - Maximum number of conversation turns (user + model
    pairs) to keep from session history. When set to a positive integer, only
    the most recent N turns are included in the prompt. Defaults to `nil`
    (unlimited).
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
    :before_tool_callback,
    :after_tool_callback,
    :on_tool_error_callback,
    :max_history_turns,
    callbacks: [],
    description: "",
    tools: [],
    sub_agents: [],
    _peer_agents: [],
    max_iterations: 25,
    iteration_delay_ms: 0,
    tool_config: nil,
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
          before_tool_callback: (map(), map(), map() -> {:cont, map()} | {:halt, any()}) | nil,
          after_tool_callback: (map(), map(), map(), any() -> any()) | nil,
          on_tool_error_callback:
            (map(), map(), map(), term() ->
               {:retry, any()} | {:fallback, any()} | {:error, any()})
            | nil,
          max_history_turns: pos_integer() | nil,
          callbacks: [module()],
          description: String.t(),
          tools: [map()],
          sub_agents: [map()],
          max_iterations: pos_integer(),
          iteration_delay_ms: non_neg_integer(),
          tool_config: map() | nil,
          generate_config: map(),
          disallow_transfer_to_parent: boolean(),
          disallow_transfer_to_peers: boolean()
        }

  require Logger

  @doc """
  Create a new LLM agent.

  Applies any skills from the `:skills` option, builds the struct, and
  wires parent/peer references for sub-agent transfer.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = ADK.Skill.apply_to_opts(opts, Keyword.get(opts, :skills, []))
    opts = Keyword.drop(opts, [:skills])

    unless Keyword.get(opts, :name),
      do: raise(ArgumentError, "LlmAgent requires :name")

    unless Keyword.get(opts, :model),
      do: raise(ArgumentError, "LlmAgent requires :model")

    agent = struct!(__MODULE__, opts)
    wire_parent(agent)
  end

  defp wire_parent(%__MODULE__{sub_agents: []} = agent), do: agent

  defp wire_parent(%__MODULE__{sub_agents: subs} = agent) when is_list(subs) do
    # Create a minimal parent reference (no sub_agents to avoid circularity)
    parent_ref = %__MODULE__{
      name: agent.name,
      model: agent.model,
      instruction: agent.instruction,
      description: agent.description
    }

    # First pass: recursively wire children
    wired_subs =
      Enum.map(subs, fn
        %__MODULE__{} = child ->
          %{child | parent_agent: parent_ref}
          |> wire_parent()

        other ->
          other
      end)

    # Second pass: set peer agents (siblings excluding self)
    wired_subs =
      Enum.map(wired_subs, fn
        %__MODULE__{} = child ->
          peers =
            Enum.filter(wired_subs, fn
              %__MODULE__{name: n} -> n != child.name
              _ -> false
            end)

          %{child | _peer_agents: peers}

        other ->
          other
      end)

    %{agent | sub_agents: wired_subs}
  end

  defp wire_parent(agent), do: agent

  defp format_error_for_llm({:api_error, 403, msg}),
    do: "API key not valid or insufficient permissions (HTTP 403): #{msg}"

  defp format_error_for_llm({:api_error, status, msg}), do: "API error (HTTP #{status}): #{msg}"
  defp format_error_for_llm({:request_failed, reason}), do: "Request failed: #{inspect(reason)}"
  defp format_error_for_llm(other), do: inspect(other)

  # ---------- Protocol Implementation ----------

  defimpl ADK.Agent do
    def name(agent), do: agent.name
    def description(agent), do: agent.description || ""
    def sub_agents(agent), do: agent.sub_agents

    def run(agent, ctx) do
      ADK.Agent.LlmAgent.do_run(ctx, agent, 0, [])
    end
  end

  # ---------- Real Execution Pipeline ----------

  @doc """
  Run the agent's execution pipeline.

  This handles the iterative loop of generation and tool execution.

  The `tool_call_history` parameter tracks tool calls across iterations to detect
  stalls (when the same tool with identical arguments is called repeatedly).
  """
  @spec do_run(ADK.Context.t(), t(), non_neg_integer(), list()) :: [ADK.Event.t()]
  def do_run(ctx, agent, iteration, _tool_call_history)
      when iteration >= agent.max_iterations do
    Logger.warning(
      "[LlmAgent] Max iterations (#{agent.max_iterations}) reached for agent #{agent.name}"
    )

    error_msg =
      "Agent reached maximum tool call iterations (#{agent.max_iterations}). The response may be incomplete."

    error_event =
      ADK.Event.new(%{
        invocation_id: ctx.invocation_id,
        author: agent.name,
        content: %{role: :model, parts: [%{text: error_msg}]},
        error: error_msg
      })

    maybe_append_event(ctx.session_pid, error_event)
    ADK.Context.emit_event(ctx, error_event)
    [error_event]
  end

  def do_run(ctx, agent, iteration, tool_call_history) do
    Logger.info(
      "[LlmAgent] #{agent.name} iteration=#{iteration}/#{agent.max_iterations} invocation=#{ctx.invocation_id}"
    )

    # Rate-limit-friendly delay between iterations (skip first iteration)
    if iteration > 0 and agent.iteration_delay_ms > 0 do
      Logger.info(
        "[LlmAgent] #{agent.name} iteration=#{iteration} delay=#{agent.iteration_delay_ms}ms"
      )

      Process.sleep(agent.iteration_delay_ms)
    end

    # Build LLM request
    request = build_request(ctx, agent)

    # Run before_model plugins
    plugins = ctx.plugins || []

    {plugin_skip, request} =
      case ADK.Plugin.run_before_model(plugins, ctx, request) do
        {:skip, response} -> {true, response}
        {:ok, modified_request} -> {false, modified_request}
      end

    if plugin_skip do
      case request do
        {:ok, response} ->
          event = event_from_response(response, ctx, agent)
          event = maybe_save_output_to_state(event, agent)
          maybe_append_event(ctx.session_pid, event)
          ADK.Context.emit_event(ctx, event)
          [event]

        {:error, reason} ->
          error_event =
            ADK.Event.error(reason, invocation_id: ctx.invocation_id, author: agent.name)

          ADK.Context.emit_event(ctx, error_event)
          [error_event]
      end
    else
      # Run before_model callbacks
      callbacks = (agent.callbacks || []) ++ (ctx.callbacks || [])
      cb_ctx = %{agent: agent, context: ctx, request: request}

      case ADK.Callback.run_before(callbacks, :before_model, cb_ctx) do
        {:halt, {:ok, response}} ->
          event = event_from_response(response, ctx, agent)
          event = maybe_save_output_to_state(event, agent)
          maybe_append_event(ctx.session_pid, event)
          ADK.Context.emit_event(ctx, event)
          [event]

        {:halt, {:error, reason}} ->
          error_event =
            ADK.Event.error(reason, invocation_id: ctx.invocation_id, author: agent.name)

          ADK.Context.emit_event(ctx, error_event)
          [error_event]

        {:cont, _cb_ctx} ->
          # Call the LLM
          case ADK.LLM.generate(agent.model, request) do
            {:ok, %{content: nil} = response} ->
              # Empty/nil content — log finish_reason for debugging.
              # On iteration 0 this is rare; after tool calls it may indicate
              # a Gemini API issue (e.g. MALFORMED_FUNCTION_CALL).
              finish_reason = Map.get(response, :finish_reason)

              Logger.warning(
                "[LlmAgent] #{agent.name} iteration=#{iteration} nil content " <>
                  "(finish_reason=#{inspect(finish_reason)})"
              )

              # Always return a fallback event so the user gets feedback
              error_msg =
                if iteration > 0 do
                  "(The model returned an empty response after tool execution)"
                else
                  "The model returned an empty response. This may indicate a configuration issue or unsupported request."
                end

              fallback_event =
                ADK.Event.new(%{
                  invocation_id: ctx.invocation_id,
                  author: agent.name,
                  content: %{
                    role: :model,
                    parts: [%{text: error_msg}]
                  },
                  error: :nil_content
                })

              maybe_append_event(ctx.session_pid, fallback_event)
              ADK.Context.emit_event(ctx, fallback_event)
              [fallback_event]

            {:ok, %{partial: true} = response} ->
              # Partial (streaming chunk) response — emit and break the loop
              event = event_from_response(response, ctx, agent)
              ADK.Context.emit_event(ctx, event)
              [event]

            {:ok, raw_response} ->
              # Run after_model plugins
              response_from_plugin = ADK.Plugin.run_after_model(plugins, ctx, {:ok, raw_response})
              # Run after_model callbacks (can modify response)
              after_cb_ctx = %{agent: agent, context: ctx}

              response =
                ADK.Callback.run_after(
                  callbacks,
                  :after_model,
                  response_from_plugin,
                  after_cb_ctx
                )

              response =
                case response do
                  {:ok, r} -> r
                  other -> other
                end

              event = event_from_response(response, ctx, agent)

              case extract_function_calls(response) do
                [] ->
                  if response[:finish_reason] == "MALFORMED_FUNCTION_CALL" do
                    case detect_stall([:malformed], tool_call_history) do
                      {:stalled, :malformed} ->
                        stall_msg =
                          "Detected repeated tool call loop: Agent is repeatedly generating malformed function calls. Please check your system instructions or tool definitions."

                        Logger.warning(
                          "[LlmAgent] #{agent.name} iteration=#{iteration} STALL DETECTED: malformed function call loop"
                        )

                        stall_event =
                          ADK.Event.new(%{
                            invocation_id: ctx.invocation_id,
                            author: agent.name,
                            content: %{
                              role: :model,
                              parts: [%{text: stall_msg}]
                            },
                            error: :stall_detected
                          })

                        maybe_append_event(ctx.session_pid, event)
                        maybe_append_event(ctx.session_pid, stall_event)
                        ADK.Context.emit_event(ctx, event)
                        ADK.Context.emit_event(ctx, stall_event)
                        [event, stall_event]

                      :ok ->
                        Logger.warning(
                          "[LlmAgent] #{agent.name} encountered MALFORMED_FUNCTION_CALL, forcing retry."
                        )

                        error_msg =
                          "System Error: Your function call was malformed. #{response[:finish_message]}. Please output a valid structured tool call using JSON."

                        error_event =
                          ADK.Event.new(%{
                            invocation_id: ctx.invocation_id,
                            author: "system",
                            content: %{role: :user, parts: [%{text: error_msg}]}
                          })

                        maybe_append_event(ctx.session_pid, event)
                        maybe_append_event(ctx.session_pid, error_event)
                        ADK.Context.emit_event(ctx, event)
                        ADK.Context.emit_event(ctx, error_event)

                        [
                          event,
                          error_event
                          | do_run(ctx, agent, iteration + 1, tool_call_history ++ [:malformed])
                        ]
                    end
                  else
                    # No tool calls — this is the final response
                    event = maybe_save_output_to_state(event, agent)
                    maybe_append_event(ctx.session_pid, event)
                    ADK.Context.emit_event(ctx, event)
                    [event]
                  end

                calls ->
                  # Tool calls — execute them and loop
                  tool_names = Enum.map(calls, fn c -> c["name"] || Map.get(c, :name, "?") end)

                  Logger.info(
                    "[LlmAgent] #{agent.name} iteration=#{iteration} tool_calls=#{inspect(tool_names)}"
                  )

                  # Check for stalls — detect if the same tool with identical args
                  # is being called repeatedly (more than twice)
                  call_signatures =
                    Enum.map(calls, fn c ->
                      {get_call_name(c), get_call_args(c)}
                    end)

                  case detect_stall(call_signatures, tool_call_history) do
                    {:stalled, stalled_call} ->
                      {tool_name, _args} = stalled_call

                      stall_msg =
                        "Detected repeated tool call loop: '#{tool_name}' has been called " <>
                          "with identical arguments more than twice. Please try a different approach " <>
                          "or provide different arguments."

                      Logger.warning(
                        "[LlmAgent] #{agent.name} iteration=#{iteration} STALL DETECTED: #{tool_name}"
                      )

                      stall_event =
                        ADK.Event.new(%{
                          invocation_id: ctx.invocation_id,
                          author: agent.name,
                          content: %{
                            role: :model,
                            parts: [%{text: stall_msg}]
                          },
                          error: :stall_detected
                        })

                      maybe_append_event(ctx.session_pid, event)
                      maybe_append_event(ctx.session_pid, stall_event)
                      ADK.Context.emit_event(ctx, event)
                      ADK.Context.emit_event(ctx, stall_event)
                      [event, stall_event]

                    :ok ->
                      ADK.Context.emit_event(ctx, event)
                      tool_results = execute_tools(ctx, agent, calls)
                      updated_history = tool_call_history ++ call_signatures

                      # Check for exit_loop, transfer, or normal continuation
                      exit_loop = Enum.find(tool_results, &Map.get(&1, :exit_loop))
                      transfer = Enum.find(tool_results, &Map.get(&1, :transfer_to_agent))

                      cond do
                        exit_loop ->
                          exit_reason = exit_loop[:result] || "Exiting loop"

                          escalate_event =
                            ADK.Event.new(%{
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
                              content: %{
                                role: :model,
                                parts: [%{text: "Transferring to #{target_name}"}]
                              },
                              actions: %ADK.EventActions{transfer_to_agent: target_name}
                            })

                          ADK.Context.emit_event(ctx, transfer_event)

                          # Execute the target agent within the same invocation
                          target_events =
                            case find_transfer_target(agent, target_name) do
                              nil ->
                                []

                              target_agent ->
                                target_ctx = %{ctx | agent: target_agent}
                                do_run(target_ctx, target_agent, 0, [])
                            end

                          [event, transfer_event | target_events]

                        true ->
                          # Build tool response and loop
                          response_parts =
                            Enum.map(tool_results, fn tr ->
                              # Format results/errors into the response map
                              response =
                                cond do
                                  tr[:error] || tr["error"] ->
                                    %{"error" => inspect(tr[:error] || tr["error"])}

                                  tr[:result] ->
                                    wrap_tool_response(tr[:result])

                                  true ->
                                    wrap_tool_response("")
                                end

                              fr = %{
                                name: tr.name,
                                response: response
                              }

                              # Preserve tool_call_id for backends that need it (e.g. Anthropic)
                              fr = if tr[:id], do: Map.put(fr, :id, tr[:id]), else: fr

                              %{function_response: fr}
                            end)

                          response_event =
                            ADK.Event.new(%{
                              invocation_id: ctx.invocation_id,
                              author: agent.name,
                              content: %{role: :user, parts: response_parts}
                            })

                          ADK.Context.emit_event(ctx, response_event)

                          maybe_append_event(ctx.session_pid, event)
                          maybe_append_event(ctx.session_pid, response_event)

                          [
                            event,
                            response_event | do_run(ctx, agent, iteration + 1, updated_history)
                          ]
                      end

                      # cond
                  end

                  # stall detection case
              end

            {:error, reason} ->
              # Run on_model_error plugins
              plugin_error_res = ADK.Plugin.run_on_model_error(plugins, ctx, {:error, reason})

              case plugin_error_res do
                {:ok, response} ->
                  # Plugin handled the error and provided a fake response, proceed as if LLM returned it
                  event = event_from_response(response, ctx, agent)
                  event = maybe_save_output_to_state(event, agent)
                  maybe_append_event(ctx.session_pid, event)
                  ADK.Context.emit_event(ctx, event)
                  [event]

                {:error, final_reason} ->
                  # Run on_model_error callbacks
                  cb_ctx_err = %{agent: agent, context: ctx}

                  case ADK.Callback.run_on_error(callbacks, {:error, final_reason}, cb_ctx_err) do
                    {:retry, _new_cb_ctx} ->
                      do_run(ctx, agent, iteration + 1, tool_call_history)

                    {:fallback, {:ok, response}} ->
                      event = event_from_response(response, ctx, agent)
                      event = maybe_save_output_to_state(event, agent)
                      maybe_append_event(ctx.session_pid, event)
                      ADK.Context.emit_event(ctx, event)
                      [event]

                    {:error, final_reason} ->
                      error_event =
                        ADK.Event.new(%{
                          invocation_id: ctx.invocation_id,
                          author: agent.name,
                          content: %{
                            role: :model,
                            parts: [%{text: "Error: #{format_error_for_llm(final_reason)}"}]
                          },
                          error: final_reason
                        })

                      maybe_append_event(ctx.session_pid, error_event)

                      ADK.Context.emit_event(ctx, error_event)
                      [error_event]
                  end

                  # closes Callback.run_on_error
              end

              # closes plugin_error_res case
          end

          # end LLM generate case
      end

      # end before_model callback case
    end

    # end plugin_skip else
  end

  @doc """
  Build the LLM request map from the current context and agent configuration.

  Assembles everything the LLM provider needs for a generation call:

    * `:model` — the model identifier from the agent config
    * `:instruction` — compiled system instruction (may include dynamic parts)
    * `:messages` — conversation history from the context
    * `:tools` — tool declarations for all effective tools
    * `:agent_name` — the agent's name (used for multi-agent routing)
    * `:generate_config` — generation parameters (temperature, etc.) when set
    * `:tool_config` — tool-calling mode/constraints when set
    * `:live_connect_config` — real-time/streaming options from `RunConfig`
      (audio transcription, affective dialog, proactivity, session resumption,
      realtime input config, context window compression)

  Planner configuration (e.g. `ADK.Planner.BuiltIn`) is applied last, which
  may add thinking/reasoning parameters to the request.

  The returned map is passed directly to the LLM provider module
  (e.g. `ADK.LLM.Gemini`, `ADK.LLM.OpenAI`, `ADK.LLM.Anthropic`).
  """
  @spec build_request(ADK.Context.t(), t()) :: map()
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

    request =
      if ctx.run_config do
        live_connect =
          [
            {:output_audio_transcription, ctx.run_config.output_audio_transcription},
            {:input_audio_transcription, ctx.run_config.input_audio_transcription},
            {:enable_affective_dialog, ctx.run_config.enable_affective_dialog},
            {:proactivity, ctx.run_config.proactivity},
            {:session_resumption, ctx.run_config.session_resumption},
            {:realtime_input_config, ctx.run_config.realtime_input_config},
            {:context_window_compression, ctx.run_config.context_window_compression}
          ]
          |> Enum.reject(fn
            {:enable_affective_dialog, v} -> is_nil(v)
            {_k, v} -> !v
          end)
          |> Map.new()

        if map_size(live_connect) > 0 do
          Map.put(request, :live_connect_config, live_connect)
        else
          request
        end
      else
        request
      end

    request =
      case agent.generate_config do
        config when is_map(config) and map_size(config) > 0 ->
          Map.put(request, :generate_config, config)

        _ ->
          request
      end

    # Apply tool_config if set on agent
    request =
      case agent.tool_config do
        config when is_map(config) and map_size(config) > 0 ->
          Map.put(request, :tool_config, config)

        _ ->
          request
      end

    # Apply planner if present
    apply_planner(request, agent.planner)
  end

  defp apply_planner(request, nil), do: request

  defp apply_planner(request, %ADK.Planner.BuiltIn{} = planner) do
    ADK.Planner.BuiltIn.apply_thinking_config(planner, request)
  end

  defp apply_planner(request, %ADK.Planner.PlanReAct{} = _planner) do
    planning_instruction = ADK.Planner.PlanReAct.build_planning_instruction(nil, request)

    request =
      if planning_instruction do
        base = request[:instruction] || ""
        combined = base <> "\n\n" <> planning_instruction

        request
        |> Map.put(:instruction, combined)
        |> Map.put(:dynamic_system_instruction, combined)
      else
        request
      end

    # Strip :thought from message parts (thought parts are internal planning artifacts)
    messages =
      Enum.map(request[:messages] || [], fn msg ->
        parts = Enum.map(msg.parts || [], fn part -> Map.delete(part, :thought) end)
        %{msg | parts: parts}
      end)

    Map.put(request, :messages, messages)
  end

  defp apply_planner(request, _planner), do: request

  @doc """
  Compile the instruction string, merging global + agent instruction
  and substituting `{key}` state variables.
  """
  @spec compile_instruction(ADK.Context.t(), t()) :: String.t()
  def compile_instruction(ctx, agent) do
    base = resolve_instruction(agent.instruction, ctx)

    base
    |> prepend_global_instruction(agent.global_instruction, ctx)
    |> append_transfer_instructions(agent.sub_agents)
    |> substitute_state_variables(ctx)
  end

  defp prepend_global_instruction(base, nil, _ctx), do: base
  defp prepend_global_instruction(base, "", _ctx), do: base

  defp prepend_global_instruction(base, global, ctx) do
    resolved_global = resolve_instruction(global, ctx)
    resolved_global <> "\n" <> base
  end

  defp append_transfer_instructions(base, []), do: base

  defp append_transfer_instructions(base, subs) do
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

  @doc """
  Compute the full tool list including auto-generated transfer tools.
  """
  @spec effective_tools(t()) :: [map()]
  def effective_tools(agent) do
    targets = transfer_targets(agent)

    transfer_tools =
      case targets do
        [] -> []
        agents -> ADK.Tool.TransferToAgent.tools_for_sub_agents(agents)
      end

    agent.tools ++ transfer_tools
  end

  @doc """
  Find a transfer target agent by name.
  """
  @spec find_transfer_target(t(), String.t()) :: t() | nil
  def find_transfer_target(agent, target_name) do
    # Check sub-agents
    result =
      Enum.find(agent.sub_agents || [], fn a ->
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
  @spec transfer_targets(t()) :: [t()]
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
  @spec get_available_agent_names(t()) :: [String.t()]
  def get_available_agent_names(%__MODULE__{} = root_agent) do
    collect_agent_names(root_agent, []) |> Enum.reverse()
  end

  @doc """
  Find an agent by name in the tree, or raise with a helpful error.
  """
  @spec get_agent_to_run(t(), String.t()) :: {:ok, t()}
  def get_agent_to_run(%__MODULE__{} = root_agent, agent_name) do
    case find_agent(root_agent, agent_name) do
      nil ->
        available = get_available_agent_names(root_agent)

        raise ArgumentError, """
        Agent '#{agent_name}' not found.
        Available agents: #{Enum.join(available, ", ")}

        Possible causes:
        - Typo in agent name
        - Agent not registered as a sub_agent
        - Agent was removed or renamed

        Suggested fixes:
        - Check spelling matches one of: #{Enum.join(available, ", ")}
        - Verify the agent is included in the sub_agents list
        """

      agent ->
        {:ok, agent}
    end
  end

  @doc """
  Clone an agent with optional overrides.
  """
  @spec clone(t(), map()) :: t()
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

  defp maybe_append_event(nil, _event), do: :ok
  defp maybe_append_event(pid, event), do: ADK.Session.append_event(pid, event)

  defp get_history(nil), do: []

  defp get_history(pid) do
    ADK.Session.get_events(pid)
    |> Enum.map(fn e ->
      content = e.content || %{}
      # Handle both atom and string keys for parts
      parts = Map.get(content, :parts) || Map.get(content, "parts") || []
      role = infer_message_role(e, parts)
      %{role: role, parts: parts}
    end)
  end

  defp build_messages(ctx) do
    history = get_history(ctx.session_pid)

    max_turns = if ctx.agent, do: ctx.agent.max_history_turns, else: nil
    history = truncate_history(history, max_turns)

    # Only append user_content if it's not already present in history.
    # Runner.run appends the user event to the session before calling do_run,
    # so on subsequent tool-loop iterations the message is already in history.
    # Appending it again causes the LLM to see a duplicate user request after
    # tool responses, which triggers infinite tool-call loops.
    user_msg =
      case ctx.user_content do
        %{text: text} -> [%{role: :user, parts: [%{text: text}]}]
        nil -> []
        text when is_binary(text) -> [%{role: :user, parts: [%{text: text}]}]
        _ -> []
      end

    user_msg =
      if user_msg != [] and last_user_message_matches?(history, user_msg) do
        []
      else
        user_msg
      end

    (history ++ user_msg)
    |> ADK.Transcript.Repair.repair()
  end

  # Check if the LAST user-role message in history already contains the text.
  # This prevents duplicate user messages when Runner.run has already appended
  # the user event to the session, without falsely deduplicating when the user
  # intentionally sends the same text again later in the conversation.
  # Text is compared after trimming whitespace to handle minor formatting differences.
  defp last_user_message_matches?(history, [%{role: :user, parts: [%{text: text}]}]) do
    trimmed_text = String.trim(text)

    history
    |> Enum.reverse()
    |> Enum.filter(fn msg ->
      msg.role == :user and not has_function_response?(msg.parts)
    end)
    |> List.first()
    |> case do
      %{parts: parts} ->
        Enum.any?(parts, fn
          %{text: part_text} -> String.trim(part_text) == trimmed_text
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp last_user_message_matches?(_history, _user_msg), do: false

  # Determine the correct Gemini role for a session event.
  # Tool response events (containing function_response parts) must use :user role
  # even though their author is the agent name, because Gemini requires
  # function_response parts to appear in user-role messages.
  defp infer_message_role(event, parts) do
    role = Map.get(event.content || %{}, :role) || Map.get(event.content || %{}, "role")

    cond do
      role in [:user, "user"] ->
        :user

      role in [:model, "model"] ->
        :model

      has_function_response?(parts) ->
        :user

      event.author == "user" ->
        :user

      true ->
        :model
    end
  end

  

  defp has_function_response?(parts) do
    Enum.any?(parts, fn
      %{function_response: _} -> true
      %{"function_response" => _} -> true
      _ -> false
    end)
  end

  defp has_text_only?(parts) do
    Enum.all?(parts, fn
      %{text: _} -> true
      %{"text" => _} -> true
      _ -> false
    end)
  end

  defp truncate_history(history, nil), do: history

  defp truncate_history(history, n) when is_integer(n) and n > 0 do
    max_messages = n * 2
    len = length(history)

    if len <= max_messages do
      history
    else
      # Drop from the front, but find a clean cut point where we don't
      # split a function_call / function_response pair.
      truncated = Enum.drop(history, len - max_messages)
      drop_leading_orphaned_responses(truncated)
    end
  end

  # Drop messages from the front that are orphaned by truncation.
  # After truncation, the history may start with:
  # 1. User messages containing only function_response parts (orphaned tool results
  #    with no preceding function_call)
  # 2. Model messages containing function_call parts (which Gemini rejects if not
  #    preceded by a user or function_response turn)
  # We drop these leading messages until we reach a clean starting point.
  defp drop_leading_orphaned_responses([]), do: []

  defp drop_leading_orphaned_responses([msg | rest] = messages) do
    role = msg[:role]
    parts = msg[:parts] || []

    has_func_response =
      Enum.any?(parts, fn
        %{function_response: _} -> true
        %{"function_response" => _} -> true
        _ -> false
      end)

    has_func_call =
      Enum.any?(parts, fn
        %{function_call: _} -> true
        %{"function_call" => _} -> true
        _ -> false
      end)

    cond do
      # Drop user messages that only contain function_response (orphaned tool results)
      has_func_response ->
        drop_leading_orphaned_responses(rest)

      # Drop model messages with function_call at the start (no preceding user turn)
      # Gemini requires: "function call turn comes immediately after a user turn
      # or after a function response turn"
      role == :model and has_func_call ->
        drop_leading_orphaned_responses(rest)

      # Any other message (user text, model text) — this is fine as a start
      true ->
        messages
    end
  end

  @doc """
  Conditionally save the agent's output to the session state.
  """
  @spec maybe_save_output_to_state(ADK.Event.t(), t()) :: ADK.Event.t()
  def maybe_save_output_to_state(event, agent) do
    output_key = agent.output_key

    cond do
      is_nil(output_key) ->
        event

      event.partial == true ->
        event

      event.author != agent.name ->
        Logger.debug(
          "Skipping output save for agent #{agent.name}: event authored by #{event.author}"
        )

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
      # Wrap entire tool execution in try-rescue to ensure tool_call_id is ALWAYS
      # preserved, even if callbacks, plugins, or the tool itself raises an exception.
      # This prevents state corruption where the LLM receives error responses without
      # being able to map them back to the specific tool_call_id.
      try do
        # Extract tool name safely (handles both atom and string keys from different LLM backends)
        tool_name = get_call_name(call)

        result =
          case Map.get(tools_map, tool_name) do
            nil ->
              handle_unknown_tool(call, tool_name, agent, ctx)

            tool ->
              handle_known_tool(call, tool_name, tool, agent, ctx)
          end

        maybe_add_call_id(result, call)
      catch
        kind, reason ->
          # Catch ALL exceptions including Erlang errors, throws, and exits
          tool_name = get_call_name(call)
          error_msg = "Tool '#{tool_name}' execution failed with #{kind}: #{inspect(reason)}"
          
          Logger.error(
            "[LlmAgent] Tool execution exception: #{tool_name} - #{error_msg}\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )

          %{name: tool_name, error: error_msg}
          |> maybe_add_call_id(call)
      end
    end)
  end

  # Safely extract tool name from a call, handling both string and atom keys
  # Different LLM backends may use different key formats
  defp get_call_name(call) do
    call[:name] || call["name"] || Map.get(call, :name) || Map.get(call, "name") || "unknown"
  end

  # Safely extract tool args from a call, handling both string and atom keys
  defp get_call_args(call) do
    call[:args] || call["args"] || Map.get(call, :args) || Map.get(call, "args") || %{}
  end

  defp maybe_add_call_id(result, call) do
    if call[:id], do: Map.put(result, :id, call[:id]), else: result
  end

  defp handle_unknown_tool(call, tool_name, agent, ctx) do
    err_msg = "Unknown tool: #{tool_name}"
    callbacks = (agent.callbacks || []) ++ (ctx.callbacks || [])
    tool_args = get_call_args(call)

    tool_cb_ctx = %{
      agent: agent,
      context: ctx,
      tool: %{name: tool_name},
      tool_args: tool_args
    }

    # Agent functional callback
    func_res =
      if agent.on_tool_error_callback do
        agent.on_tool_error_callback.(
          %{name: tool_name},
          tool_args,
          %{},
          {:error, err_msg}
        )
      else
        {:error, err_msg}
      end

    case func_res do
      {:fallback, {:ok, fallback_res}} ->
        %{name: tool_name, result: fallback_res}

      {:fallback, fallback_res} ->
        %{name: tool_name, result: fallback_res}

      {:ok, fallback_res} ->
        %{name: tool_name, result: fallback_res}

      _ ->
        # Plugins
        plugins = ctx.plugins || []

        case ADK.Plugin.run_on_tool_error(plugins, ctx, tool_name, {:error, err_msg}) do
          {:ok, recovered} ->
            %{name: tool_name, result: recovered}

          {:error, reason} ->
            # Module callbacks
            case ADK.Callback.run_on_tool_error(callbacks, {:error, reason}, tool_cb_ctx) do
              {:fallback, fallback_res} -> fallback_res
              _ -> %{name: tool_name, error: reason}
            end
        end
    end
  end

  defp handle_known_tool(call, tool_name, tool, agent, ctx) do
    tool_ctx = ADK.ToolContext.new(ctx, call[:id] || "call-1", tool)
    callbacks = (agent.callbacks || []) ++ (ctx.callbacks || [])
    plugins = ctx.plugins || []
    call_args = get_call_args(call)
    tool_cb_ctx = %{agent: agent, context: ctx, tool: tool, tool_args: call_args}

    {plugin_skip, plugin_res, call_args} =
      case ADK.Plugin.run_before_tool(plugins, ctx, tool.name, call_args) do
        {:skip, response} -> {true, response, call_args}
        {:ok, modified_args} -> {false, nil, modified_args}
      end

    result =
      if plugin_skip do
        plugin_res
      else
        # 1. Agent functional before_tool_callback
        {skip_func, call_args} =
          if agent.before_tool_callback do
            case agent.before_tool_callback.(tool, call_args, tool_ctx) do
              nil -> {false, call_args}
              %{} = modified_args -> {false, modified_args}
              {:cont, modified_args} -> {false, modified_args}
              {:halt, {:ok, _} = res} -> {true, res}
              {:halt, res} -> {true, {:ok, res}}
              {:ok, _} = res -> {true, res}
              res -> {true, {:ok, res}}
            end
          else
            {false, call_args}
          end

        if skip_func do
          call_args
        else
          tool_cb_ctx = %{tool_cb_ctx | tool_args: call_args}

          case ADK.Callback.run_before(callbacks, :before_tool, tool_cb_ctx) do
            {:halt, halted_result} ->
              halted_result

            {:cont, modified_ctx} ->
              call_args = Map.get(modified_ctx, :tool_args, call_args)

              res =
                try do
                  ADK.Telemetry.Contract.tool_span(
                    %{tool_name: tool.name, agent_name: agent.name},
                    fn ->
                      run_tool(tool, tool_ctx, call_args)
                    end
                  )
                rescue
                  e ->
                    error_msg =
                      "Tool '#{tool.name}' execution failed with exception: #{Exception.message(e)}"

                    Logger.error(
                      "[LlmAgent] #{error_msg}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
                    )

                    {:error, error_msg}
                catch
                  kind, reason ->
                    error_msg = "Tool '#{tool.name}' crashed: #{inspect({kind, reason})}"
                    Logger.error("[LlmAgent] #{error_msg}")
                    {:error, error_msg}
                end

              case res do
                {:error, reason} ->
                  # functional on_tool_error
                  func_err_res =
                    if agent.on_tool_error_callback do
                      case agent.on_tool_error_callback.(
                             tool,
                             call_args,
                             tool_ctx,
                             {:error, reason}
                           ) do
                        nil -> res
                        {:fallback, {:ok, _} = fb} -> fb
                        {:fallback, fb} -> {:ok, fb}
                        {:ok, _} = fb -> fb
                        %{} = fb -> {:ok, fb}
                        _ -> res
                      end
                    else
                      res
                    end

                  if func_err_res != res do
                    func_err_res
                  else
                    # Plugins
                    case ADK.Plugin.run_on_tool_error(
                           plugins,
                           ctx,
                           tool.name,
                           {:error, reason}
                         ) do
                      {:ok, recovered} ->
                        {:ok, recovered}

                      plugin_err ->
                        # Module callbacks
                        case ADK.Callback.run_on_tool_error(
                               callbacks,
                               plugin_err,
                               tool_cb_ctx
                             ) do
                          {:retry, ret_ctx} ->
                            ret_args = Map.get(ret_ctx, :tool_args, call_args)

                            try do
                              ADK.Telemetry.Contract.tool_span(
                                %{tool_name: tool.name, agent_name: agent.name},
                                fn ->
                                  run_tool(tool, tool_ctx, ret_args)
                                end
                              )
                            rescue
                              e ->
                                error_msg =
                                  "Tool '#{tool.name}' execution failed with exception on retry: #{Exception.message(e)}"

                                Logger.error(
                                  "[LlmAgent] #{error_msg}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
                                )

                                {:error, error_msg}
                            catch
                              kind, reason ->
                                error_msg =
                                  "Tool '#{tool.name}' crashed on retry: #{inspect({kind, reason})}"

                                Logger.error("[LlmAgent] #{error_msg}")
                                {:error, error_msg}
                            end

                          {:fallback, fallback_res} ->
                            fallback_res

                          err ->
                            err
                        end
                    end
                  end

                other ->
                  other
              end
          end
        end
      end

    # functional after_tool_callback
    result =
      if agent.after_tool_callback do
        unwrapped_res =
          case result do
            {:ok, val} -> val
            other -> other
          end

        case agent.after_tool_callback.(tool, call_args, tool_ctx, unwrapped_res) do
          nil -> result
          {:ok, _} = new_res -> new_res
          %{} = new_res -> {:ok, new_res}
          new_res -> {:ok, new_res}
        end
      else
        result
      end

    result = ADK.Callback.run_after(callbacks, :after_tool, result, tool_cb_ctx)
    result = ADK.Plugin.run_after_tool(plugins, ctx, tool.name, result)

    case result do
      {:transfer_to_agent, target} ->
        %{name: tool_name, result: "Transferring to #{target}", transfer_to_agent: target}

      {:exit_loop, reason} ->
        %{name: tool_name, result: reason, exit_loop: true}

      {:ok, value} ->
        %{name: tool_name, result: ADK.Tool.ResultGuard.maybe_truncate(value)}

      {:error, reason} ->
        %{name: tool_name, error: reason}
    end
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
    acc = [name | acc]

    Enum.reduce(subs, acc, fn sub, inner_acc ->
      collect_agent_names(sub, inner_acc)
    end)
  end

  defp collect_agent_names(%{name: name}, acc), do: [name | acc]

  defp find_agent(%{name: name} = agent, name), do: agent

  defp find_agent(%{sub_agents: subs}, target) when is_list(subs) do
    Enum.find_value(subs, fn sub -> find_agent(sub, target) end)
  end

  defp find_agent(_, _), do: nil

  # Detect if any tool call signature appears more than twice in the history.
  # Returns `{:stalled, signature}` if a stall is detected, `:ok` otherwise.
  # A stall occurs when the same tool with identical arguments is called
  # repeatedly, indicating the agent is stuck in a loop.
  defp detect_stall(current_signatures, history) do
    # Check each current signature against the history
    Enum.find_value(current_signatures, fn signature ->
      # A stall is defined as the exact same tool call signature appearing 3 times consecutively.
      # Since `history` has the previous calls, we check if the last two calls match this signature.
      case Enum.reverse(history) do
        [^signature, ^signature | _] ->
          {:stalled, signature}

        _ ->
          # Fallback to general count to prevent unbounded loops across the entire session
          if Enum.count(history, fn h -> h == signature end) >= 4 do
            {:stalled, signature}
          else
            nil
          end
      end
    end) || :ok
  end
end
