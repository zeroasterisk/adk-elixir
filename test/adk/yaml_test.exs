defmodule ADK.YamlTest do
  use ExUnit.Case

  test "load_agent/1 parses YAML into LlmAgent" do
    yaml = """
    name: test_agent
    model: gemini-2.5-flash
    instruction: "You are a tester."
    description: "A test agent"
    max_iterations: 5
    tools:
      - name: tool_one
        description: does something
    """

    assert {:ok, agent} = ADK.Yaml.load_agent(yaml)
    assert agent.name == "test_agent"
    assert agent.model == "gemini-2.5-flash"
    assert agent.instruction == "You are a tester."
    assert agent.description == "A test agent"
    assert agent.max_iterations == 5
    assert [%{name: "tool_one", description: "does something"}] = agent.tools
  end

  test "load_agent/1 handles sub_agents" do
    yaml = """
    name: parent
    instruction: "parent"
    sub_agents:
      - name: child
        instruction: "child"
    """

    assert {:ok, agent} = ADK.Yaml.load_agent(yaml)
    assert agent.name == "parent"
    assert length(agent.sub_agents) == 1
    
    child = hd(agent.sub_agents)
    assert child.name == "child"
    assert child.instruction == "child"
  end

  test "load_agent!/1 raises on bad yaml" do
    assert_raise ArgumentError, fn ->
      ADK.Yaml.load_agent!("name: [bad yaml")
    end
  end
end
