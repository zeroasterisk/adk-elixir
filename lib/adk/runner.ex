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

    # Start a session process
    {:ok, session_pid} =
      ADK.Session.start_link(
        app_name: runner.app_name,
        user_id: user_id,
        session_id: session_id
      )

    invocation_id = generate_id()

    # Append user event
    user_event =
      ADK.Event.new(%{
        invocation_id: invocation_id,
        author: "user",
        content: %{parts: [%{text: message_text(message)}]}
      })

    ADK.Session.append_event(session_pid, user_event)

    # Build context
    ctx = %ADK.Context{
      invocation_id: invocation_id,
      session_pid: session_pid,
      agent: runner.agent,
      user_content: message
    }

    # Run the agent
    agent_events = runner.agent.module.run(ctx)

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

  defp generate_id do
    "inv-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
