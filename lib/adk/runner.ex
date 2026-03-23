defmodule ADK.Runner do
  @moduledoc """
  Orchestrates agent execution — creates sessions, runs agents, collects events.
  """

  defstruct [:app_name, :agent, :session_store, :artifact_service, :memory_store, plugins: []]

  @type t :: %__MODULE__{
          app_name: String.t(),
          agent: ADK.Agent.t(),
          session_store: {module(), keyword()} | nil,
          artifact_service: {module(), keyword()} | nil,
          memory_store: {module(), keyword()} | nil,
          plugins: [{module(), term()}]
        }

  @doc """
  Create a new Runner.

  ## Options

    * `:app_name` - application name (required)
    * `:agent` - the agent to run (required)
    * `:session_store` - optional `{Module, opts}` tuple for session persistence
    * `:artifact_service` - optional `{Module, opts}` tuple for artifact storage
    * `:memory_store` - optional `{Module, opts}` tuple for long-term memory

  ## Examples

      iex> agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      iex> runner = ADK.Runner.new(app_name: "test", agent: agent)
      iex> runner.app_name
      "test"
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      app_name: Keyword.fetch!(opts, :app_name),
      agent: Keyword.fetch!(opts, :agent),
      session_store: Keyword.get(opts, :session_store),
      artifact_service: Keyword.get(opts, :artifact_service),
      memory_store: Keyword.get(opts, :memory_store),
      plugins: Keyword.get(opts, :plugins, [])
    }
  end

  @doc """
  Run an agent with a message, returning a list of events.

  ## Examples

      iex> agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      iex> runner = %ADK.Runner{app_name: "test", agent: agent}
      iex> events = ADK.Runner.run(runner, "user1", "sess1", %{text: "hi"})
      iex> is_list(events)
      true
  """
  @spec run(t(), String.t(), String.t(), map() | String.t(), keyword()) :: [ADK.Event.t()]
  def run(%__MODULE__{} = runner, user_id, session_id, message, opts \\ []) do
    message = normalize_message(message)

    # Find existing session or start a new one (with store if configured)
    session_pid =
      case ADK.Session.lookup(runner.app_name, user_id, session_id) do
        {:ok, pid} ->
          pid

        :error ->
          session_opts =
            [
              app_name: runner.app_name,
              user_id: user_id,
              session_id: session_id
            ]
            |> maybe_add_store(runner.session_store)

          case ADK.Session.start_supervised(session_opts) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end
      end

    invocation_id = generate_id()

    # Append user event
    user_event =
      ADK.Event.new(%{
        invocation_id: invocation_id,
        author: "user",
        content: %{parts: [%{text: message_text(message)}]}
      })

    ADK.Session.append_event(session_pid, user_event)

    callbacks = Keyword.get(opts, :callbacks, [])
    policies = Keyword.get(opts, :policies, [])
    run_config = Keyword.get(opts, :run_config)
    on_event = Keyword.get(opts, :on_event)

    # Build context
    {artifact_mod, artifact_opts} = resolve_artifact_service(runner.artifact_service)

    # Sticky transfer: find the agent that should handle this turn.
    # If a previous turn transferred to a sub-agent, subsequent messages
    # should route to that agent (mirrors Python's _find_agent_to_run).
    active_agent = find_active_agent(runner.agent, session_pid)

    ctx = %ADK.Context{
      invocation_id: invocation_id,
      session_pid: session_pid,
      agent: active_agent,
      user_content: message,
      callbacks: callbacks,
      policies: policies,
      run_config: run_config,
      artifact_service: if(artifact_mod, do: {artifact_mod, artifact_opts}),
      memory_store: runner.memory_store,
      app_name: runner.app_name,
      user_id: user_id,
      on_event: on_event
    }

    # Gather global plugins, combine with runner-specific plugins
    plugins =
      (get_plugins() ++ Map.get(runner, :plugins, []))
      |> Enum.map(fn
        {mod, st} when is_atom(mod) -> {mod, st}
        mod when is_atom(mod) -> {mod, []}
      end)
      |> Enum.uniq_by(fn {mod, _} -> mod end)

    telemetry_meta = %{
  agent_name: ADK.Agent.name(runner.agent),
  session_id: session_id,
  "gen_ai.system": "gcp.vertex.agent",
  "gen_ai.operation.name": "invoke_agent",
  "gen_ai.agent.name": ADK.Agent.name(runner.agent),
  "gen_ai.conversation.id": session_id,
  "gen_ai.agent.description": Map.get(runner.agent, :description, "")
}

    # Run before_run plugins — emit telemetry around the full agent execution
    {agent_events, _plugins} =
      ADK.Telemetry.span([:adk, :agent], telemetry_meta, fn ->
        case ADK.Plugin.run_before(plugins, ctx) do
        {:halt, result, updated_plugins} ->
          {result, updated_plugins}

        {:cont, ctx, updated_plugins} ->
          # Store updated plugin states in context so LlmAgent can call
          # per-model/per-tool/on_event plugin hooks inline during execution.
          ctx = %{ctx | plugins: updated_plugins}

          # Run input policy filters
          case ADK.Policy.run_input_filters(policies, ctx.user_content, ctx) do
            {:halt, events} ->
              {events, updated_plugins}

            {:cont, filtered_content} ->
              ctx = %{ctx | user_content: filtered_content}

              # Run before_agent callbacks
              cb_ctx = %{agent: runner.agent, context: ctx}

              events =
                case ADK.Callback.run_before(callbacks, :before_agent, cb_ctx) do
                  {:halt, events} ->
                    events

                  {:cont, cb_ctx} ->
                    events = ADK.Agent.run(cb_ctx.context.agent, cb_ctx.context)
                    ADK.Callback.run_after(callbacks, :after_agent, events, cb_ctx)
                end

              # Run output policy filters
              events = ADK.Policy.run_output_filters(policies, events, ctx)

              # Run after_run plugins
              ADK.Plugin.run_after(updated_plugins, events, ctx)
          end
      end
      end)

    # Append events to session and emit via on_event callback.
    # Context.emit_event/2 deduplicates by event ID, so events already emitted
    # by LlmAgent inline (during execution) won't fire again here.
    # Agents that don't call emit_event (e.g., Custom) will have their events
    # fired here as the fallback.
    Enum.each(agent_events, fn event ->
      ADK.Session.append_event(session_pid, event)
      ADK.Context.emit_event(ctx, event)
    end)

    # Save session to store if configured
    if runner.session_store do
      ADK.Session.save(session_pid)
    end

    # Stop the session process
    if Keyword.get(opts, :stop_session, true) do
      GenServer.stop(session_pid, :normal)
    end

    agent_events
  end

  @doc """
  Run an agent with streaming — calls `on_event` callback for each event as it's produced.

  Events are delivered in real-time via the agent's execution pipeline. The `on_event`
  callback is wired into the execution context so it fires immediately as each event
  is generated (model response, tool call, tool result), not after the full run completes.

  Runs in a supervised Task under `ADK.RunnerSupervisor` and sends a `{:adk_done, events}`
  message to the caller when complete. If the supervisor is not running, falls back to
  synchronous execution.

  ## Options

  Same as `run/5` plus:
    * `:on_event` — `(ADK.Event.t() -> any())` callback invoked for each event in real-time
    * `:reply_to` — pid to send `{:adk_done, events}` when complete (default: `self()`)

  ## Examples

      ADK.Runner.run_streaming(runner, "user1", "sess1", "hi",
        on_event: fn event -> IO.inspect(event) end)
  """
  @spec run_streaming(t(), String.t(), String.t(), map() | String.t(), keyword()) :: [ADK.Event.t()]
  def run_streaming(%__MODULE__{} = runner, user_id, session_id, message, opts \\ []) do
    # on_event is threaded through context — fires for each event as the agent produces it.
    # This is a synchronous call; the on_event callback is invoked inline during execution.
    run(runner, user_id, session_id, message, opts)
  end

  @doc """
  Run an agent with async streaming — non-blocking, events delivered via messages.

  Spawns a supervised Task that runs the agent with the given `on_event` callback.
  Messages sent to `reply_to` (default: `self()`):
    - `{:adk_event, event}` for each event (via on_event callback)
    - `{:adk_done, events}` when the run completes
    - `{:adk_error, reason}` on failure

  Returns `{:ok, task_pid}`.

  ## Examples

      {:ok, _pid} = ADK.Runner.run_async(runner, "user1", "sess1", "hi")
      receive do
        {:adk_event, event} -> IO.inspect(event, label: "event")
        {:adk_done, events} -> IO.puts("Done, \#{length(events)} events")
      end
  """
  @spec run_async(t(), String.t(), String.t(), map() | String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def run_async(%__MODULE__{} = runner, user_id, session_id, message, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to, self())
    runner_opts = Keyword.drop(opts, [:reply_to])

    # Wrap on_event to also send {:adk_event, event} messages
    caller_on_event = Keyword.get(runner_opts, :on_event)
    streaming_on_event = fn event ->
      send(reply_to, {:adk_event, event})
      if caller_on_event, do: caller_on_event.(event)
    end
    runner_opts = Keyword.put(runner_opts, :on_event, streaming_on_event)

    supervisor = ADK.RunnerSupervisor

    if Process.whereis(supervisor) do
      {:ok, pid} = Task.Supervisor.start_child(supervisor, fn ->
        try do
          events = run(runner, user_id, session_id, message, runner_opts)
          send(reply_to, {:adk_done, events})
        rescue
          e -> send(reply_to, {:adk_error, Exception.message(e)})
        end
      end)
      {:ok, pid}
    else
      # Fallback: spawn unsupervised
      pid = spawn(fn ->
        try do
          events = run(runner, user_id, session_id, message, runner_opts)
          send(reply_to, {:adk_done, events})
        rescue
          e -> send(reply_to, {:adk_error, Exception.message(e)})
        end
      end)
      {:ok, pid}
    end
  end

  defp normalize_message(msg) when is_binary(msg), do: %{text: msg}
  defp normalize_message(%{text: _} = msg), do: msg
  defp normalize_message(msg), do: %{text: inspect(msg)}

  defp message_text(%{text: t}), do: t
  defp message_text(t) when is_binary(t), do: t

  defp maybe_add_store(opts, nil), do: opts
  defp maybe_add_store(opts, store), do: Keyword.put(opts, :store, store)

  defp get_plugins do
    if Process.whereis(ADK.Plugin.Registry) do
      ADK.Plugin.list()
    else
      []
    end
  end

  defp resolve_artifact_service(nil), do: {nil, []}
  defp resolve_artifact_service({mod, opts}), do: {mod, opts}
  defp resolve_artifact_service(mod) when is_atom(mod), do: {mod, []}

  defp generate_id do
    "inv-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  @doc """
  Find the agent that should handle the current turn based on transfer history.

  Scans session events backward for the last `transfer_to_agent` action.
  If found, looks up that agent in the agent tree and returns it.
  If not found or the target is a non-LLM agent (SequentialAgent, LoopAgent),
  returns the root agent.

  This mirrors Python ADK's `Runner._find_agent_to_run()`.
  """
  @spec find_active_agent(ADK.Agent.t(), pid() | nil) :: ADK.Agent.t()
  def find_active_agent(root_agent, nil), do: root_agent

  def find_active_agent(root_agent, session_pid) do
    events = ADK.Session.get_events(session_pid)

    # Scan backward for the last transfer_to_agent action
    last_transfer =
      events
      |> Enum.reverse()
      |> Enum.find_value(fn event ->
        case event.actions do
          %ADK.EventActions{transfer_to_agent: name} when is_binary(name) and name != "" ->
            name

          _ ->
            nil
        end
      end)

    case last_transfer do
      nil ->
        root_agent

      target_name ->
        # Find the agent in the tree
        case find_agent_in_tree(root_agent, target_name) do
          nil -> root_agent
          agent -> agent
        end
    end
  end

  defp find_agent_in_tree(agent, target_name) do
    if ADK.Agent.name(agent) == target_name do
      agent
    else
      agent
      |> ADK.Agent.sub_agents()
      |> Enum.find_value(fn sub ->
        find_agent_in_tree(sub, target_name)
      end)
    end
  end
end
