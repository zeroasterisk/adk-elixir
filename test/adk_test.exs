defmodule ADKTest do
  use ExUnit.Case, async: false

  test "ADK.new creates an agent" do
    agent = ADK.new("bot", model: "test", instruction: "Help")
    assert agent.name == "bot"
    assert agent.module == ADK.Agent.LlmAgent
  end

  test "ADK.chat returns final text" do
    ADK.LLM.Mock.set_responses(["Hello!"])
    agent = ADK.new("bot", model: "test", instruction: "Help")
    result = ADK.chat(agent, "Hi")
    assert result == "Hello!"
  end

  test "ADK.run returns events" do
    ADK.LLM.Mock.set_responses(["Response"])
    agent = ADK.new("bot", model: "test", instruction: "Help")
    events = ADK.run(agent, "Hi")
    assert is_list(events)
    assert length(events) >= 1
  end

  test "ADK.sequential creates pipeline" do
    a1 = ADK.new("a", model: "test")
    a2 = ADK.new("b", model: "test")
    pipeline = ADK.sequential([a1, a2])
    assert pipeline.name == "sequential"
    assert pipeline.module == ADK.Agent.SequentialAgent
    assert length(pipeline.sub_agents) == 2
  end
end
