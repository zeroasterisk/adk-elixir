defmodule ADK.Agent.AgentCloneTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.Agent.LoopAgent
  alias ADK.Agent.SequentialAgent
  alias ADK.Agent.ParallelAgent
  alias ADK.Agent.Clone

  defp llm(opts) do
    defaults = [name: "agent", model: "test", instruction: "help"]
    LlmAgent.new(Keyword.merge(defaults, opts))
  end

  # Helper: check parent_agent is wired to an agent with the expected name
  # (Elixir is immutable so we can't create true circular refs; check by name)
  defp assert_parent_name(sub, expected_name) do
    assert sub.parent_agent != nil
    assert sub.parent_agent.name == expected_name
  end

  # test 1
  test "basic LlmAgent clone with name update" do
    original =
      llm(
        name: "llm_agent",
        description: "An LLM agent",
        instruction: "You are a helpful assistant."
      )

    cloned = Clone.clone(original, %{name: "cloned_llm_agent"})

    assert cloned.name == "cloned_llm_agent"
    assert cloned.description == "An LLM agent"
    assert cloned.instruction == "You are a helpful assistant."
    assert cloned.parent_agent == nil
    assert cloned.sub_agents == []
    assert is_struct(cloned, LlmAgent)

    assert original.name == "llm_agent"
  end

  # test 2
  test "clone agent with sub-agents" do
    sub1 = llm(name: "sub_agent1", description: "First sub-agent")
    sub2 = llm(name: "sub_agent2", description: "Second sub-agent")

    original =
      SequentialAgent.new(name: "parent_agent", description: "Parent", sub_agents: [sub1, sub2])

    cloned = Clone.clone(original, %{name: "cloned_parent"})

    assert cloned.name == "cloned_parent"
    assert cloned.parent_agent == nil
    assert length(cloned.sub_agents) == 2
    assert Enum.at(cloned.sub_agents, 0).name == "sub_agent1"
    assert Enum.at(cloned.sub_agents, 1).name == "sub_agent2"
    assert_parent_name(Enum.at(cloned.sub_agents, 0), "cloned_parent")
    assert_parent_name(Enum.at(cloned.sub_agents, 1), "cloned_parent")

    # Cloned sub-agents are independent copies (different name lineage)
    assert Enum.at(cloned.sub_agents, 0).parent_agent.name !=
             Enum.at(original.sub_agents, 0).parent_agent

    assert original.name == "parent_agent"
    assert length(original.sub_agents) == 2
  end

  # test 3
  test "three-level nested agent clone" do
    leaf1 = llm(name: "leaf1", description: "First leaf agent")
    leaf2 = llm(name: "leaf2", description: "Second leaf agent")

    middle1 =
      SequentialAgent.new(name: "middle1", description: "First middle agent", sub_agents: [leaf1])

    middle2 =
      ParallelAgent.new(name: "middle2", description: "Second middle agent", sub_agents: [leaf2])

    root =
      LoopAgent.new(
        name: "root_agent",
        description: "Root",
        max_iterations: 5,
        sub_agents: [middle1, middle2]
      )

    cloned_root = Clone.clone(root, %{name: "cloned_root"})

    assert cloned_root.name == "cloned_root"
    assert cloned_root.max_iterations == 5
    assert cloned_root.parent_agent == nil
    assert length(cloned_root.sub_agents) == 2
    assert is_struct(cloned_root, LoopAgent)

    cloned_middle1 = Enum.at(cloned_root.sub_agents, 0)
    cloned_middle2 = Enum.at(cloned_root.sub_agents, 1)

    assert cloned_middle1.name == "middle1"
    assert_parent_name(cloned_middle1, "cloned_root")
    assert length(cloned_middle1.sub_agents) == 1
    assert is_struct(cloned_middle1, SequentialAgent)

    assert cloned_middle2.name == "middle2"
    assert_parent_name(cloned_middle2, "cloned_root")
    assert is_struct(cloned_middle2, ParallelAgent)

    cloned_leaf1 = Enum.at(cloned_middle1.sub_agents, 0)
    cloned_leaf2 = Enum.at(cloned_middle2.sub_agents, 0)

    assert cloned_leaf1.name == "leaf1"
    assert_parent_name(cloned_leaf1, "middle1")
    assert cloned_leaf2.name == "leaf2"
    assert_parent_name(cloned_leaf2, "middle2")

    # Original unchanged
    assert root.name == "root_agent"
    assert Enum.at(root.sub_agents, 0).name == "middle1"
  end

  # test 4
  test "multiple clones from same original" do
    original = llm(name: "original_agent", description: "Agent for multiple cloning")
    clone1 = Clone.clone(original, %{name: "clone1"})
    clone2 = Clone.clone(original, %{name: "clone2"})

    assert clone1.name == "clone1"
    assert clone2.name == "clone2"
    # Clones are independent
    refute clone1.name == clone2.name
  end

  # test 5
  test "clone with complex configuration preserves all fields" do
    original =
      LlmAgent.new(
        name: "complex_agent",
        model: "test",
        description: "A complex agent with many settings",
        instruction: "You are a specialized assistant.",
        global_instruction: "Always be helpful and accurate.",
        disallow_transfer_to_parent: true,
        disallow_transfer_to_peers: true
      )

    cloned = Clone.clone(original, %{name: "complex_clone"})

    assert cloned.name == "complex_clone"
    assert cloned.description == "A complex agent with many settings"
    assert cloned.instruction == "You are a specialized assistant."
    assert cloned.global_instruction == "Always be helpful and accurate."
    assert cloned.disallow_transfer_to_parent == true
    assert cloned.disallow_transfer_to_peers == true
    assert cloned.parent_agent == nil
    assert cloned.sub_agents == []
  end

  # test 6
  test "clone without updates preserves original values" do
    original = llm(name: "test_agent", description: "Test agent")
    cloned = Clone.clone(original)

    assert cloned.name == "test_agent"
    assert cloned.description == "Test agent"
  end

  # test 7
  test "clone with multiple updates" do
    original =
      llm(
        name: "original_agent",
        description: "Original description",
        instruction: "Original instruction"
      )

    cloned =
      Clone.clone(original, %{
        name: "updated_agent",
        description: "Updated description",
        instruction: "Updated instruction"
      })

    assert cloned.name == "updated_agent"
    assert cloned.description == "Updated description"
    assert cloned.instruction == "Updated instruction"
  end

  # test 8
  test "clone with sub_agents deep copy - new objects" do
    sub = llm(name: "sub_agent", description: "Sub agent")

    original =
      LlmAgent.new(name: "root_agent", model: "test", instruction: "h", sub_agents: [sub])

    cloned = Clone.clone(original, %{name: "cloned_root"})

    assert cloned.sub_agents |> Enum.at(0) |> Map.get(:name) == "sub_agent"
    assert_parent_name(Enum.at(cloned.sub_agents, 0), "cloned_root")

    # Cloned sub has parent pointing to cloned root, original sub has parent pointing to original
    cloned_sub_parent = Enum.at(cloned.sub_agents, 0).parent_agent.name
    orig_sub_parent = Enum.at(original.sub_agents, 0).parent_agent.name
    assert cloned_sub_parent == "cloned_root"
    assert orig_sub_parent == "root_agent"
  end

  # test 9
  test "clone with invalid field raises ArgumentError" do
    original = llm(name: "test_agent")

    assert_raise ArgumentError, ~r/Cannot update nonexistent fields/, fn ->
      Clone.clone(original, %{invalid_field: "value"})
    end
  end

  # test 10
  test "clone with parent_agent field raises ArgumentError" do
    original = llm(name: "test_agent")

    assert_raise ArgumentError, ~r/Cannot update `parent_agent` field in clone/, fn ->
      Clone.clone(original, %{parent_agent: nil})
    end
  end

  # test 11
  test "clone preserves agent type for all agent types" do
    llm_orig = LlmAgent.new(name: "llm_test", model: "test", instruction: "h")
    assert is_struct(Clone.clone(llm_orig), LlmAgent)

    seq_orig = SequentialAgent.new(name: "seq_test")
    assert is_struct(Clone.clone(seq_orig), SequentialAgent)

    par_orig = ParallelAgent.new(name: "par_test")
    assert is_struct(Clone.clone(par_orig), ParallelAgent)

    loop_orig = LoopAgent.new(name: "loop_test")
    assert is_struct(Clone.clone(loop_orig), LoopAgent)
  end

  # test 12
  test "clone LoopAgent with max_iterations update" do
    original = LoopAgent.new(name: "loop_test")
    cloned = Clone.clone(original, %{max_iterations: 10})
    assert is_struct(cloned, LoopAgent)
    assert cloned.max_iterations == 10
  end

  # test 13
  test "clone with nil update" do
    original = llm(name: "test_agent", description: "Test agent")
    cloned = Clone.clone(original, nil)
    assert cloned.name == "test_agent"
    # Clone produces a struct with same values (Elixir is value-based)
    assert cloned.description == "Test agent"
  end

  # test 14
  test "clone with empty map update" do
    original = llm(name: "test_agent", description: "Test agent")
    cloned = Clone.clone(original, %{})
    assert cloned.name == "test_agent"
    assert cloned.description == "Test agent"
  end

  # test 15
  test "clone with sub_agents in update overrides original sub_agents" do
    orig_sub1 = llm(name: "original_sub1")
    orig_sub2 = llm(name: "original_sub2")
    new_sub1 = llm(name: "new_sub1")
    new_sub2 = llm(name: "new_sub2")

    original = SequentialAgent.new(name: "original_agent", sub_agents: [orig_sub1, orig_sub2])
    cloned = Clone.clone(original, %{name: "cloned_agent", sub_agents: [new_sub1, new_sub2]})

    assert cloned.name == "cloned_agent"
    assert length(cloned.sub_agents) == 2
    assert Enum.at(cloned.sub_agents, 0).name == "new_sub1"
    assert Enum.at(cloned.sub_agents, 1).name == "new_sub2"
    assert_parent_name(Enum.at(cloned.sub_agents, 0), "cloned_agent")

    assert original.name == "original_agent"
    assert Enum.at(original.sub_agents, 0).name == "original_sub1"
  end

  # test 16
  test "clone shallow copies tools list (new list, same tool references)" do
    tool =
      ADK.Tool.FunctionTool.new(:my_tool,
        description: "A tool",
        func: fn _ctx, _args -> {:ok, "result"} end,
        parameters: %{}
      )

    original =
      LlmAgent.new(name: "original_agent", model: "test", instruction: "h", tools: [tool])

    cloned = Clone.clone(original)

    # Both have the same tool by name/description
    assert Enum.at(original.tools, 0).name == Enum.at(cloned.tools, 0).name
    assert Enum.at(original.tools, 0).description == Enum.at(cloned.tools, 0).description

    # Tool function references are preserved (same function)
    assert Enum.at(original.tools, 0).func == Enum.at(cloned.tools, 0).func
  end

  # test 17: convenience function on agent module
  test "LlmAgent.clone/1 is a convenience wrapper" do
    original = llm(name: "bot")
    cloned = LlmAgent.clone(original, %{name: "bot2"})
    assert cloned.name == "bot2"
    assert is_struct(cloned, LlmAgent)
  end
end
