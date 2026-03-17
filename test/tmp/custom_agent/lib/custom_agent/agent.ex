defmodule CustomAgent.Agent do
  @moduledoc """
  The main agent for `CustomAgent`.

  Uses ADK's LlmAgent with tools for greeting and calculating.
  """

  @doc """
  Run the agent with a user message.

  ## Examples

      iex> CustomAgent.Agent.run("Hello!")

  """
  def run(message, opts \\ []) do
    agent = build(opts)

    runner =
      ADK.Runner.new(
        app_name: "custom_agent",
        agent: agent,
        session_store: {ADK.Session.Store.InMemory, []}
      )

    case ADK.Runner.run(runner, "default_user", "default_session", message) do
      events when is_list(events) ->
        events
        |> Enum.filter(&(&1.author == agent.name))
        |> Enum.map(& &1.content)
        |> Enum.map_join("\n", fn
          %{text: text} -> text
          text when is_binary(text) -> text
          other -> inspect(other)
        end)

      {:error, reason} ->
        "Error: #{inspect(reason)}"
    end
  end

  @doc "Build the agent struct."
  def build(opts \\ []) do
    model = opts[:model] || Application.get_env(:custom_agent, :model, "gemini-2.5-pro")

    ADK.Agent.LlmAgent.new(
      name: "custom_agent",
      model: model,
      instruction: """
      You are a friendly pirate assistant! Arrr! 🏴‍☠️
      You help people with greetings and math. Use your tools when appropriate.
      Always stay in character as a pirate.
      """,
      tools: [
        CustomAgent.Tools.greeting_tool(),
        CustomAgent.Tools.calculator_tool()
      ]
    )
  end
end
