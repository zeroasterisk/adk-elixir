defmodule ADK.A2A.AgentCardTest do
  use ExUnit.Case, async: true

  alias ADK.A2A.AgentCard

  test "generates card from agent spec" do
    agent = ADK.Agent.LlmAgent.new(
      name: "helper",
      description: "A helpful agent",
      model: "test",
      instruction: "Help",
      tools: []
    )

    card = AgentCard.from_agent(agent, url: "http://localhost:4000/a2a")

    assert card["name"] == "helper"
    assert card["description"] == "A helpful agent"
    assert card["url"] == "http://localhost:4000/a2a"
    assert card["version"] == "1.0.0"
    assert card["capabilities"]["stateTransitionHistory"] == true
    assert card["skills"] == []
  end

  test "maps tools to skills" do
    tool = ADK.Tool.FunctionTool.new(:search,
      description: "Search the web",
      func: fn _, _ -> {:ok, "result"} end
    )

    agent = ADK.Agent.LlmAgent.new(
      name: "researcher",
      description: "Researches topics",
      model: "test",
      instruction: "Research",
      tools: [tool]
    )

    card = AgentCard.from_agent(agent, url: "http://localhost:4000/a2a")

    assert [%{"id" => "search", "name" => "search", "description" => "Search the web"}] =
             card["skills"]
  end

  test "includes provider when given" do
    agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help", tools: [])
    card = AgentCard.from_agent(agent, url: "http://x", provider: %{"name" => "Acme"})

    assert card["provider"] == %{"name" => "Acme"}
  end
end
