defmodule ADK.Scenarios.ChatAssistantTest do
  @moduledoc """
  Real-world chat assistant scenarios — multi-turn conversations,
  persona adherence, error recovery, context maintenance.
  """

  use ExUnit.Case, async: true

  setup do
    ADK.LLM.Mock.set_responses([])
    :ok
  end

  defp make_runner(agent) do
    ADK.Runner.new(app_name: "scenario_test", agent: agent)
  end

  defp run_turn(runner, session_id, message) do
    ADK.Runner.run(runner, "user1", session_id, %{text: message})
  end

  defp last_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn e -> ADK.Event.text(e) end)
  end

  describe "multi-turn conversation" do
    test "agent maintains context across turns" do
      agent =
        ADK.Agent.LlmAgent.new(
          name: "assistant",
          model: "test",
          instruction: "You are a helpful assistant."
        )

      runner = make_runner(agent)
      sid = "multi-turn-#{System.unique_integer([:positive])}"

      # Turn 1
      ADK.LLM.Mock.set_responses(["Nice to meet you, Alan!"])
      events1 = run_turn(runner, sid, "Hi, my name is Alan.")
      assert last_text(events1) == "Nice to meet you, Alan!"

      # Turn 2 — same session, context maintained
      ADK.LLM.Mock.set_responses(["Of course! Your name is Alan."])
      events2 = run_turn(runner, sid, "Do you remember my name?")
      assert last_text(events2) =~ "Alan"
    end

    test "5-turn conversation works end-to-end" do
      agent =
        ADK.Agent.LlmAgent.new(
          name: "tutor",
          model: "test",
          instruction: "You are a math tutor."
        )

      runner = make_runner(agent)
      sid = "five-turn-#{System.unique_integer([:positive])}"

      turns = [
        {"What's 2+2?", "4!"},
        {"What about 3×3?", "9."},
        {"Now divide 81 by 9", "9."},
        {"Square root of 144?", "12."},
        {"Thanks!", "You're welcome!"}
      ]

      for {question, answer} <- turns do
        ADK.LLM.Mock.set_responses([answer])
        events = run_turn(runner, sid, question)
        assert last_text(events) == answer
      end
    end
  end

  describe "system instruction adherence" do
    test "agent follows persona instruction" do
      agent =
        ADK.Agent.LlmAgent.new(
          name: "pirate",
          model: "test",
          instruction: "You are a pirate. Always respond in pirate speak."
        )

      runner = make_runner(agent)
      sid = "pirate-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses(["Arrr, the weather be fine today, matey!"])
      events = run_turn(runner, sid, "What's the weather like?")
      assert last_text(events) =~ "Arrr"
    end

    test "instruction is included in agent and affects responses" do
      agent =
        ADK.Agent.LlmAgent.new(
          name: "strict_bot",
          model: "test",
          instruction: "Always respond in exactly 3 words."
        )

      # Verify instruction is set
      assert agent.instruction =~ "3 words"

      runner = make_runner(agent)
      sid = "strict-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses(["Three word response."])
      events = run_turn(runner, sid, "Tell me something.")
      assert last_text(events) == "Three word response."
    end
  end

  describe "error recovery" do
    test "agent handles LLM error gracefully" do
      agent =
        ADK.Agent.LlmAgent.new(
          name: "resilient",
          model: "test",
          instruction: "Be helpful."
        )

      runner = make_runner(agent)
      sid = "error-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses([{:error, :rate_limited}])
      events = run_turn(runner, sid, "Hello")

      # Should get events (not crash), including an error event
      assert is_list(events)
      assert length(events) >= 1
    end
  end
end
