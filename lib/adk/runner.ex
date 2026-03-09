defmodule ADK.Runner do
  @moduledoc """
  Orchestrates agent execution — creates sessions, runs agents, collects events.
  """

  defstruct [:app_name, :agent, :session_store, :artifact_service, :memory_store]

  @type t :: %__MODULE__{
          app_name: String.t(),
          agent: ADK.Agent.t(),
          session_store: {module(), keyword()} | nil,
          artifact_service: {module(), keyword()} | nil,
          memory_store: {module(), keyword()} | nil
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
      memory_store: Keyword.get(opts, :memory_store)
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

    # Build context
    {artifact_mod, artifact_opts} = resolve_artifact_service(runner.artifact_service)

    ctx = %ADK.Context{
      invocation_id: invocation_id,
      session_pid: session_pid,
      agent: runner.agent,
      user_content: message,
      callbacks: callbacks,
      policies: policies,
      run_config: run_config,
      artifact_service: if(artifact_mod, do: {artifact_mod, artifact_opts}),
      memory_store: runner.memory_store,
      app_name: runner.app_name,
      user_id: user_id
    }

    # Gather global plugins
    plugins = get_plugins()

    telemetry_meta = %{
      agent_name: ADK.Agent.name(runner.agent),
      session_id: session_id
    }

    # Run before_run plugins — emit telemetry around the full agent execution
    {agent_events, _plugins} =
      ADK.Telemetry.span([:adk, :agent], telemetry_meta, fn ->
        case ADK.Plugin.run_before(plugins, ctx) do
        {:halt, result, updated_plugins} ->
          {result, updated_plugins}

        {:cont, ctx, updated_plugins} ->
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

    # Emit events via on_event callback (for streaming) and append to session
    on_event = Keyword.get(opts, :on_event)

    Enum.each(agent_events, fn event ->
      ADK.Session.append_event(session_pid, event)
      if on_event, do: on_event.(event)
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

  Events are delivered in real-time via an event collector process that the agent
  reports to as events are generated. Returns the final list of agent events.

  ## Options

  Same as `run/5` plus:
    * `:on_event` — `(ADK.Event.t() -> any())` callback invoked for each event in real-time

  ## Examples

      ADK.Runner.run_streaming(runner, "user1", "sess1", "hi",
        on_event: fn event -> IO.inspect(event) end)
  """
  @spec run_streaming(t(), String.t(), String.t(), map() | String.t(), keyword()) :: [ADK.Event.t()]
  def run_streaming(%__MODULE__{} = runner, user_id, session_id, message, opts \\ []) do
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    runner_opts = Keyword.drop(opts, [:on_event])

    # Run in a task, with on_event callback passed through
    runner_opts = Keyword.put(runner_opts, :on_event, on_event)

    run(runner, user_id, session_id, message, runner_opts)
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
end
