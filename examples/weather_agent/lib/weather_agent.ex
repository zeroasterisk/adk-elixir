defmodule WeatherAgent do
  @moduledoc """
  A simple weather agent built with ADK Elixir.

  Demonstrates:
  - Agent definition with `ADK.Agent.LlmAgent`
  - Custom tool creation with `ADK.Tool.FunctionTool`
  - Runner usage
  - Multi-turn conversation
  """

  @doc """
  Create the weather agent.
  """
  def agent do
    ADK.Agent.LlmAgent.new(
      name: "weather_bot",
      model: model(),
      instruction: """
      You are a helpful weather assistant. You can look up current weather
      for any city using the get_weather tool. When asked about weather,
      always use the tool to get accurate data. Be concise and friendly.
      """,
      tools: [WeatherAgent.Tools.get_weather_tool()],
      description: "A weather lookup assistant"
    )
  end

  @doc """
  Create a runner for the weather agent.
  """
  def runner do
    %ADK.Runner{
      app_name: "weather_app",
      agent: agent()
    }
  end

  @doc """
  Run a single turn of conversation.

  ## Examples

      WeatherAgent.chat("What's the weather in Tokyo?")
  """
  def chat(message, user_id \\ "user1", session_id \\ "default") do
    runner()
    |> ADK.Runner.run(user_id, session_id, message)
  end

  @doc """
  Run a multi-turn conversation interactively from the terminal.
  """
  def interactive do
    IO.puts("Weather Agent - type 'quit' to exit")
    IO.puts("=" |> String.duplicate(40))
    interactive_loop("user1", "session-#{System.unique_integer([:positive])}")
  end

  defp interactive_loop(user_id, session_id) do
    case IO.gets("\nYou: ") do
      :eof -> :ok
      {:error, _} -> :ok
      input ->
        message = String.trim(input)

        if message in ["quit", "exit", "q"] do
          IO.puts("Goodbye!")
        else
          events = chat(message, user_id, session_id)

          events
          |> Enum.filter(&ADK.Event.text?/1)
          |> Enum.each(fn event ->
            IO.puts("\nWeather Bot: #{ADK.Event.text(event)}")
          end)

          interactive_loop(user_id, session_id)
        end
    end
  end

  defp model do
    System.get_env("ADK_MODEL", "gemini-flash-latest")
  end
end
