defmodule ADK.RunnerTest do
  use ExUnit.Case, async: false

  test "runner creates session, runs agent, returns events" do
    ADK.LLM.Mock.set_responses(["Hello from the bot!"])

    agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Be helpful.")
    runner = %ADK.Runner{app_name: "test_app", agent: agent}

    events = ADK.Runner.run(runner, "user1", "sess1", "Hi there!")

    assert is_list(events)
    assert length(events) >= 1

    texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
    assert "Hello from the bot!" in texts
  end

  test "runner accepts map message" do
    ADK.LLM.Mock.set_responses(["OK"])

    agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
    runner = %ADK.Runner{app_name: "test_app", agent: agent}

    events = ADK.Runner.run(runner, "user1", "sess2", %{text: "Hello"})
    assert length(events) >= 1
  end
end
