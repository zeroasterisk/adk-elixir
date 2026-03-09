defmodule MultiAgent do
  @moduledoc """
  Multi-agent example demonstrating agent transfer with ADK.

  A "router" agent delegates to specialist sub-agents:
  - **Weather Agent** — answers weather questions
  - **Math Agent** — handles math calculations

  The router decides which specialist to hand off to based on the user's query.

  ## Usage

      # Single turn
      events = MultiAgent.chat("What's the weather in Tokyo?")

      # Multi-turn conversation
      events = MultiAgent.chat("What's 2 + 2?", session_id: "my-session")
      events = MultiAgent.chat("Now multiply that by 3", session_id: "my-session")
  """

  @doc """
  Create the weather specialist agent.
  """
  def weather_agent do
    weather_tool =
      ADK.Tool.FunctionTool.new(:get_weather,
        description: "Get current weather for a city",
        func: fn _ctx, args ->
          city = args["city"] || "Unknown"
          {:ok, "Weather in #{city}: 22°C, partly cloudy"}
        end,
        parameters: %{
          type: "object",
          properties: %{city: %{type: "string", description: "City name"}},
          required: ["city"]
        }
      )

    ADK.Agent.LlmAgent.new(
      name: "weather",
      model: "test",
      instruction: "You are a weather expert. Use the get_weather tool to answer weather questions.",
      description: "Handles weather-related queries",
      tools: [weather_tool]
    )
  end

  @doc """
  Create the math specialist agent.
  """
  def math_agent do
    calc_tool =
      ADK.Tool.FunctionTool.new(:calculate,
        description: "Evaluate a math expression",
        func: fn _ctx, args ->
          expr = args["expression"] || "0"
          {:ok, "Result: #{expr} (calculated)"}
        end,
        parameters: %{
          type: "object",
          properties: %{expression: %{type: "string", description: "Math expression"}},
          required: ["expression"]
        }
      )

    ADK.Agent.LlmAgent.new(
      name: "math",
      model: "test",
      instruction: "You are a math expert. Use the calculate tool for computations.",
      description: "Handles math calculations and number questions",
      tools: [calc_tool]
    )
  end

  @doc """
  Create the router agent with both specialists as sub-agents.
  """
  def router_agent do
    ADK.Agent.LlmAgent.new(
      name: "router",
      model: "test",
      instruction: """
      You are a helpful assistant that routes questions to the right specialist.
      For weather questions, transfer to the weather agent.
      For math questions, transfer to the math agent.
      For general questions, answer directly.
      """,
      sub_agents: [weather_agent(), math_agent()]
    )
  end

  @doc """
  Run a chat message through the multi-agent system.

  ## Options
    * `:session_id` - Session ID for multi-turn conversations (default: random)
    * `:user_id` - User ID (default: "user")
  """
  @spec chat(String.t(), keyword()) :: [ADK.Event.t()]
  def chat(message, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, random_id())
    user_id = Keyword.get(opts, :user_id, "user")

    runner = %ADK.Runner{
      app_name: "multi_agent_demo",
      agent: router_agent()
    }

    ADK.Runner.run(runner, user_id, session_id, message, stop_session: false)
  end

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
