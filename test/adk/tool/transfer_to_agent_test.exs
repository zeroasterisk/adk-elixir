defmodule ADK.Tool.TransferToAgentTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.TransferToAgent
  alias ADK.Tool.FunctionTool
  alias ADK.Agent.LlmAgent

  describe "tools_for_sub_agents/1" do
    test "generates one transfer tool per sub-agent" do
      sub1 = LlmAgent.new(name: "researcher", model: "test", instruction: "Research things", description: "A research agent")
      sub2 = LlmAgent.new(name: "writer", model: "test", instruction: "Write things")

      tools = TransferToAgent.tools_for_sub_agents([sub1, sub2])

      assert length(tools) == 2
      assert Enum.all?(tools, &is_struct(&1, FunctionTool))

      [t1, t2] = tools
      assert t1.name == "transfer_to_agent_researcher"
      assert t2.name == "transfer_to_agent_writer"

      # Description includes agent description when available
      assert t1.description =~ "A research agent"
      assert t2.description =~ "writer"
    end

    test "returns empty list for no sub-agents" do
      assert TransferToAgent.tools_for_sub_agents([]) == []
    end

    test "tool func returns transfer signal" do
      sub = LlmAgent.new(name: "helper", model: "test", instruction: "Help")
      [tool] = TransferToAgent.tools_for_sub_agents([sub])

      assert {:transfer_to_agent, "helper"} = tool.func.(nil, %{})
    end
  end

  describe "transfer?/1" do
    test "recognizes transfer signals" do
      assert TransferToAgent.transfer?({:transfer_to_agent, "agent1"})
      refute TransferToAgent.transfer?({:ok, "result"})
      refute TransferToAgent.transfer?(nil)
    end
  end

  describe "effective_tools/1" do
    test "includes transfer tools when sub_agents present" do
      sub = LlmAgent.new(name: "sub", model: "test", instruction: "Sub")
      tool = %FunctionTool{name: "search", description: "Search", func: fn _, _ -> {:ok, "r"} end, parameters: %{}}

      agent = LlmAgent.new(name: "parent", model: "test", instruction: "Parent", tools: [tool], sub_agents: [sub])

      effective = LlmAgent.effective_tools(agent)
      assert length(effective) == 2
      names = Enum.map(effective, & &1.name)
      assert "search" in names
      assert "transfer_to_agent_sub" in names
    end

    test "no transfer tools when no sub_agents" do
      tool = %FunctionTool{name: "search", description: "Search", func: fn _, _ -> {:ok, "r"} end, parameters: %{}}
      agent = LlmAgent.new(name: "solo", model: "test", instruction: "Solo", tools: [tool])

      effective = LlmAgent.effective_tools(agent)
      assert length(effective) == 1
      assert hd(effective).name == "search"
    end
  end
end
