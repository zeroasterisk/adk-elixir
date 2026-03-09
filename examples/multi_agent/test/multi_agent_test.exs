defmodule MultiAgentTest do
  use ExUnit.Case, async: false

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  describe "agent construction" do
    test "router agent has two sub-agents" do
      router = MultiAgent.router_agent()
      assert length(router.sub_agents) == 2
      names = Enum.map(router.sub_agents, &ADK.Agent.name/1)
      assert "weather" in names
      assert "math" in names
    end

    test "router agent has transfer tools" do
      router = MultiAgent.router_agent()
      tools = ADK.Agent.LlmAgent.effective_tools(router)
      names = Enum.map(tools, & &1.name)
      assert "transfer_to_agent_weather" in names
      assert "transfer_to_agent_math" in names
    end

    test "weather agent has get_weather tool" do
      agent = MultiAgent.weather_agent()
      assert length(agent.tools) == 1
      assert hd(agent.tools).name == "get_weather"
    end

    test "math agent has calculate tool" do
      agent = MultiAgent.math_agent()
      assert length(agent.tools) == 1
      assert hd(agent.tools).name == "calculate"
    end
  end

  describe "agent transfer" do
    test "router transfers to weather agent" do
      ADK.LLM.Mock.set_responses([
        # Router calls transfer to weather
        %{function_call: %{name: "transfer_to_agent_weather", args: %{}, id: "fc-1"}},
        # Weather agent responds
        "It's 22°C in Tokyo!"
      ])

      events = MultiAgent.chat("What's the weather in Tokyo?")

      # Should have transfer event
      transfer_events =
        Enum.filter(events, fn e ->
          e.actions && e.actions.transfer_to_agent == "weather"
        end)

      assert length(transfer_events) >= 1

      # Weather agent should respond
      texts = events |> Enum.map(&ADK.Event.text/1) |> Enum.filter(& &1)
      assert Enum.any?(texts, &String.contains?(&1, "22°C"))
    end

    test "router transfers to math agent" do
      ADK.LLM.Mock.set_responses([
        # Router calls transfer to math
        %{function_call: %{name: "transfer_to_agent_math", args: %{}, id: "fc-1"}},
        # Math agent responds
        "The answer is 4."
      ])

      events = MultiAgent.chat("What is 2 + 2?")

      transfer_events =
        Enum.filter(events, fn e ->
          e.actions && e.actions.transfer_to_agent == "math"
        end)

      assert length(transfer_events) >= 1

      texts = events |> Enum.map(&ADK.Event.text/1) |> Enum.filter(& &1)
      assert Enum.any?(texts, &String.contains?(&1, "4"))
    end

    test "router answers directly without transfer" do
      ADK.LLM.Mock.set_responses(["I'm a general assistant, happy to help!"])

      events = MultiAgent.chat("Tell me a joke")
      assert length(events) >= 1

      texts = events |> Enum.map(&ADK.Event.text/1) |> Enum.filter(& &1)
      assert Enum.any?(texts, &String.contains?(&1, "happy to help"))
    end
  end

  describe "multi-turn conversation" do
    test "maintains session across turns" do
      session_id = "multi-turn-test-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses([
        # Turn 1: transfer to weather
        %{function_call: %{name: "transfer_to_agent_weather", args: %{}, id: "fc-1"}},
        "It's sunny in Tokyo!",
        # Turn 2: transfer to math
        %{function_call: %{name: "transfer_to_agent_math", args: %{}, id: "fc-2"}},
        "42 is the answer."
      ])

      events1 = MultiAgent.chat("Weather in Tokyo?", session_id: session_id)
      assert length(events1) >= 1

      events2 = MultiAgent.chat("What is 6 * 7?", session_id: session_id)
      assert length(events2) >= 1
    end
  end
end
