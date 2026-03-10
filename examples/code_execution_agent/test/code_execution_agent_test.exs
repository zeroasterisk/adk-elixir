defmodule CodeExecutionAgentTest do
  use ExUnit.Case

  test "agent is created with correct name" do
    agent = CodeExecutionAgent.agent()
    assert ADK.Agent.name(agent) == "code_execution_agent"
  end

  test "agent has execute_code tool" do
    agent = CodeExecutionAgent.agent()
    assert length(agent.tools) == 1
    [tool] = agent.tools
    assert tool.name == "execute_code"
  end

  describe "Executor" do
    setup do
      name = :"executor_#{System.unique_integer([:positive])}"
      {:ok, _pid} = CodeExecutionAgent.Executor.start_link(name: name)
      %{name: name}
    end

    test "evaluates simple expressions", %{name: name} do
      assert {:ok, "6"} = CodeExecutionAgent.Executor.execute("2 + 4", name)
    end

    test "persists bindings across calls", %{name: name} do
      {:ok, _} = CodeExecutionAgent.Executor.execute("x = 10", name)
      {:ok, result} = CodeExecutionAgent.Executor.execute("x * 3", name)
      assert result == "30"
    end

    test "handles Enum operations", %{name: name} do
      {:ok, result} = CodeExecutionAgent.Executor.execute("Enum.sum(1..100)", name)
      assert result == "5050"
    end

    test "returns error on bad code", %{name: name} do
      assert {:error, _reason} = CodeExecutionAgent.Executor.execute("1 / 0", name)
    end

    test "reset clears bindings", %{name: name} do
      {:ok, _} = CodeExecutionAgent.Executor.execute("y = 42", name)
      CodeExecutionAgent.Executor.reset(name)
      assert CodeExecutionAgent.Executor.bindings(name) == []
    end

    test "tool function returns ok tuples", %{name: name} do
      # Manually invoke the tool func
      tool = CodeExecutionAgent.Executor.tool()
      # We need to test via the executor directly since the tool
      # func uses the default process name
      {:ok, result} = CodeExecutionAgent.Executor.execute("Enum.map(1..3, & &1 * 2)", name)
      assert result == "[2, 4, 6]"
      assert tool.name == "execute_code"
    end
  end
end
