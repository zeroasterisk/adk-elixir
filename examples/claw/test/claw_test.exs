defmodule ClawTest do
  use ExUnit.Case

  describe "Claw.Agents" do
    test "router agent is created with correct structure" do
      agent = Claw.Agents.router()
      assert agent.name == "router"
      assert agent.model == "gemini-2.0-flash-lite"
      assert length(agent.tools) == 3
      assert length(agent.sub_agents) == 2
    end

    test "coder agent has shell and file tools" do
      agent = Claw.Agents.coder()
      assert agent.name == "coder"
      tool_names = Enum.map(agent.tools, & &1.name)
      assert "shell_command" in tool_names
      assert "read_file" in tool_names
    end

    test "helper agent has datetime and file tools" do
      agent = Claw.Agents.helper()
      assert agent.name == "helper"
      tool_names = Enum.map(agent.tools, & &1.name)
      assert "datetime" in tool_names
      assert "read_file" in tool_names
    end
  end

  describe "Claw.Tools" do
    test "datetime tool returns current time" do
      tool = Claw.Tools.datetime()
      assert tool.name == "datetime"
      {:ok, result} = tool.func.(nil, %{})
      assert result =~ "Current UTC time:"
    end

    test "read_file tool reads existing file" do
      tool = Claw.Tools.read_file()
      {:ok, result} = tool.func.(nil, %{"path" => "mix.exs"})
      assert result =~ "Claw.MixProject"
    end

    test "read_file tool rejects path traversal" do
      tool = Claw.Tools.read_file()
      {:error, msg} = tool.func.(nil, %{"path" => "/etc/passwd"})
      assert msg =~ "Access denied"
    end

    test "shell_command tool runs allowed commands" do
      tool = Claw.Tools.shell_command()
      {:ok, result} = tool.func.(nil, %{"command" => "echo hello"})
      assert result =~ "hello"
    end

    test "shell_command tool rejects disallowed commands" do
      tool = Claw.Tools.shell_command()
      {:error, msg} = tool.func.(nil, %{"command" => "rm -rf /"})
      assert msg =~ "not allowed"
    end
  end

  describe "Claw.Callbacks" do
    test "before_model returns :cont" do
      ctx = %{request: %{model: "test", messages: []}}
      assert {:cont, ^ctx} = Claw.Callbacks.before_model(ctx)
    end

    test "after_model passes through ok results" do
      response = %{content: %{parts: [%{text: "hello"}]}}
      result = {:ok, response}
      assert ^result = Claw.Callbacks.after_model(result, %{})
    end
  end
end
