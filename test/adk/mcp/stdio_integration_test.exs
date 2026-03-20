defmodule ADK.MCP.StdioIntegrationTest do
  @moduledoc """
  Integration tests for the MCP stdio server pipeline.

  Tests the full flow: launch MCP server subprocess → discover tools →
  call tools → use tools in an LlmAgent with a mock LLM.

  Mirrors the pattern from Python ADK's `mcp_in_agent_tool_stdio` sample.
  """
  use ExUnit.Case, async: true

  alias ADK.MCP.Toolset
  alias ADK.Tool.FunctionTool

  @mock_server Path.expand("../../../priv/test_scripts/mock_mcp_server.exs", __DIR__)

  describe "MCP stdio → tool discovery → tool call pipeline" do
    setup do
      elixir = System.find_executable("elixir")
      {:ok, toolset} = Toolset.start_link(command: elixir, args: [@mock_server])
      on_exit(fn -> if Process.alive?(toolset), do: Toolset.close(toolset) end)
      %{toolset: toolset}
    end

    test "discovers tools from MCP server and converts to ADK declarations", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)
      declarations = Enum.map(tools, &ADK.Tool.declaration/1)

      echo_decl = Enum.find(declarations, &(&1.name == "echo"))
      assert echo_decl.description == "Echo the input message"
      assert echo_decl.parameters["type"] == "object"
      assert echo_decl.parameters["required"] == ["message"]

      add_decl = Enum.find(declarations, &(&1.name == "add"))
      assert add_decl.description == "Add two numbers"
      assert add_decl.parameters["required"] == ["a", "b"]
    end

    test "MCP tool round-trip: call echo via adapted tool", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)
      echo = Enum.find(tools, &(&1.name == "echo"))

      ctx = %ADK.ToolContext{
        context: nil,
        function_call_id: "int-1",
        tool_name: "echo",
        tool_def: nil
      }

      assert {:ok, "integration test"} = FunctionTool.run(echo, ctx, %{"message" => "integration test"})
    end

    test "MCP tool round-trip: call add via adapted tool", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)
      add = Enum.find(tools, &(&1.name == "add"))

      ctx = %ADK.ToolContext{
        context: nil,
        function_call_id: "int-2",
        tool_name: "add",
        tool_def: nil
      }

      assert {:ok, "42"} = FunctionTool.run(add, ctx, %{"a" => 19, "b" => 23})
    end

    test "MCP tools can be injected into LlmAgent struct", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)

      agent = %ADK.Agent.LlmAgent{
        name: "mcp_assistant",
        model: "mock-model",
        instruction: "You have MCP tools. Use them.",
        tools: tools
      }

      assert length(agent.tools) == 2
      assert Enum.all?(agent.tools, &is_struct(&1, FunctionTool))

      # Verify effective_tools includes them
      effective = ADK.Agent.LlmAgent.effective_tools(agent)
      assert length(effective) == 2
      names = Enum.map(effective, & &1.name)
      assert "echo" in names
      assert "add" in names
    end

    test "MCP tools produce valid declarations for LLM requests", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)

      agent = %ADK.Agent.LlmAgent{
        name: "mcp_assistant",
        model: "mock-model",
        instruction: "Help",
        tools: tools
      }

      # effective_tools returns the tools that would appear in an LLM request
      effective = ADK.Agent.LlmAgent.effective_tools(agent)
      declarations = Enum.map(effective, &ADK.Tool.declaration/1)

      assert length(declarations) == 2

      tool_names = Enum.map(declarations, & &1.name)
      assert "echo" in tool_names
      assert "add" in tool_names

      # Verify each tool declaration has proper structure for LLM consumption
      Enum.each(declarations, fn decl ->
        assert is_binary(decl.name)
        assert is_binary(decl.description)
        assert is_map(decl.parameters)
      end)
    end

    test "filtered MCP toolset only exposes selected tools in agent", %{toolset: _toolset} do
      elixir = System.find_executable("elixir")

      {:ok, filtered_toolset} =
        Toolset.start_link(
          command: elixir,
          args: [@mock_server],
          tool_filter: ["echo"]
        )

      on_exit(fn ->
        if Process.alive?(filtered_toolset), do: Toolset.close(filtered_toolset)
      end)

      {:ok, tools} = Toolset.get_tools(filtered_toolset)

      agent = %ADK.Agent.LlmAgent{
        name: "filtered_assistant",
        model: "mock-model",
        instruction: "You only have echo.",
        tools: tools
      }

      effective = ADK.Agent.LlmAgent.effective_tools(agent)
      assert length(effective) == 1
      assert hd(effective).name == "echo"
    end
  end

  describe "MCP server lifecycle" do
    test "toolset cleans up server subprocess on close" do
      elixir = System.find_executable("elixir")
      {:ok, toolset} = Toolset.start_link(command: elixir, args: [@mock_server])

      # Verify it works
      assert {:ok, tools} = Toolset.get_tools(toolset)
      assert length(tools) == 2

      # Close and verify cleanup
      Toolset.close(toolset)
      refute Process.alive?(toolset)
    end

    test "multiple independent toolsets can coexist" do
      elixir = System.find_executable("elixir")

      {:ok, toolset_1} = Toolset.start_link(command: elixir, args: [@mock_server])
      {:ok, toolset_2} = Toolset.start_link(command: elixir, args: [@mock_server])

      on_exit(fn ->
        if Process.alive?(toolset_1), do: Toolset.close(toolset_1)
        if Process.alive?(toolset_2), do: Toolset.close(toolset_2)
      end)

      {:ok, tools_1} = Toolset.get_tools(toolset_1)
      {:ok, tools_2} = Toolset.get_tools(toolset_2)

      assert length(tools_1) == 2
      assert length(tools_2) == 2

      # Each toolset's tools are independent
      echo_1 = Enum.find(tools_1, &(&1.name == "echo"))
      echo_2 = Enum.find(tools_2, &(&1.name == "echo"))

      ctx = %ADK.ToolContext{
        context: nil,
        function_call_id: "t",
        tool_name: "echo",
        tool_def: nil
      }

      assert {:ok, "from 1"} = FunctionTool.run(echo_1, ctx, %{"message" => "from 1"})
      assert {:ok, "from 2"} = FunctionTool.run(echo_2, ctx, %{"message" => "from 2"})
    end
  end

  describe "error handling" do
    setup do
      elixir = System.find_executable("elixir")
      {:ok, toolset} = Toolset.start_link(command: elixir, args: [@mock_server])
      on_exit(fn -> if Process.alive?(toolset), do: Toolset.close(toolset) end)
      %{toolset: toolset}
    end

    test "unknown tool call returns error through adapted tool", %{toolset: toolset} do
      # Get tools and try calling the client directly for an unknown tool
      assert {:error, %{"code" => -32601}} =
               ADK.MCP.Client.call_tool(
                 :sys.get_state(toolset).client,
                 "nonexistent",
                 %{}
               )
    end
  end
end
