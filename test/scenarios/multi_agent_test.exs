defmodule ADK.Scenarios.MultiAgentTest do
  @moduledoc """
  Real-world multi-agent patterns — transfers, delegation, specialist routing.
  """

  use ExUnit.Case, async: true

  setup do
    ADK.LLM.Mock.set_responses([])
    :ok
  end

  defp make_runner(agent) do
    ADK.Runner.new(app_name: "multi_agent_scenario", agent: agent)
  end

  defp run_turn(runner, session_id, message) do
    ADK.Runner.run(runner, "user1", session_id, %{text: message})
  end

  defp last_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn e -> ADK.Event.text(e) end)
  end

  describe "agent transfer" do
    test "router agent transfers to specialist based on query" do
      math_agent =
        ADK.Agent.LlmAgent.new(
          name: "math_expert",
          model: "test",
          instruction: "You are a math expert. Solve math problems."
        )

      history_agent =
        ADK.Agent.LlmAgent.new(
          name: "history_expert",
          model: "test",
          instruction: "You are a history expert. Answer history questions."
        )

      # Router uses transfer tools to delegate
      router =
        ADK.Agent.LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route questions to the appropriate expert.",
          sub_agents: [math_agent, history_agent]
        )

      runner = make_runner(router)
      sid = "transfer-#{System.unique_integer([:positive])}"

      # Router decides to transfer to math_expert
      ADK.LLM.Mock.set_responses([
        # Router transfers
        %{
          function_call: %{
            name: "transfer_to_math_expert",
            args: %{},
            id: "fc-transfer"
          }
        },
        # Math expert responds (this is the specialist's turn)
        "The square root of 144 is 12."
      ])

      events = run_turn(runner, sid, "What's the square root of 144?")

      # Should get a response from the specialist
      text = last_text(events)
      assert text != nil
      # The transfer should have happened (events include transfer)
      assert length(events) >= 1
    end
  end

  describe "agent with sub-agents" do
    test "parent agent has sub-agents available as transfer targets" do
      writer =
        ADK.Agent.LlmAgent.new(
          name: "writer",
          model: "test",
          instruction: "You write content."
        )

      reviewer =
        ADK.Agent.LlmAgent.new(
          name: "reviewer",
          model: "test",
          instruction: "You review content for quality."
        )

      editor =
        ADK.Agent.LlmAgent.new(
          name: "editor",
          model: "test",
          instruction: "Coordinate writing and review.",
          sub_agents: [writer, reviewer]
        )

      runner = make_runner(editor)
      sid = "sub-agents-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses([
        # Editor delegates to writer
        %{function_call: %{name: "transfer_to_writer", args: %{}, id: "fc-1"}},
        # Writer produces content
        "Here's a draft blog post about Elixir: Elixir is amazing because..."
      ])

      events = run_turn(runner, sid, "Write a blog post about Elixir")
      assert last_text(events) =~ "Elixir"
    end
  end
end
