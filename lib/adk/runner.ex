defmodule ADK.Runner do
  @moduledoc """
  Orchestrates agent execution — creates sessions, runs agents, collects events.
  """

  defstruct [:app_name, :agent, :session_store]

  @type t :: %__MODULE__{
          app_name: String.t(),
          agent: ADK.Agent.t(),
          session_store: module() | nil
        }

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

    # Find existing session or start a new one
    session_pid =
      case ADK.Session.lookup(runner.app_name, user_id, session_id) do
        {:ok, pid} ->
          pid

        :error ->
          {:ok, pid} =
            ADK.Session.start_supervised(
              app_name: runner.app_name,
              user_id: user_id,
              session_id: session_id
            )

          pid
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
    ctx = %ADK.Context{
      invocation_id: invocation_id,
      session_pid: session_pid,
      agent: runner.agent,
      user_content: message,
      callbacks: callbacks,
      policies: policies,
      run_config: run_config
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

    # Append agent events to session
    Enum.each(agent_events, fn event ->
      ADK.Session.append_event(session_pid, event)
    end)

    # Stop the session process
    if Keyword.get(opts, :stop_session, true) do
      GenServer.stop(session_pid, :normal)
    end

    agent_events
  end

  defp normalize_message(msg) when is_binary(msg), do: %{text: msg}
  defp normalize_message(%{text: _} = msg), do: msg
  defp normalize_message(msg), do: %{text: inspect(msg)}

  defp message_text(%{text: t}), do: t
  defp message_text(t) when is_binary(t), do: t

  defp get_plugins do
    if Process.whereis(ADK.Plugin.Registry) do
      ADK.Plugin.list()
    else
      []
    end
  end

  defp generate_id do
    "inv-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
