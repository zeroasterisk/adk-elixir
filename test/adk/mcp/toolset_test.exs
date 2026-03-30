defmodule ADK.MCP.ToolsetTest do
  use ExUnit.Case, async: true

  alias ADK.MCP.Toolset
  alias ADK.Tool.FunctionTool

  @mock_server Path.expand("../../../priv/test_scripts/mock_mcp_server.exs", __DIR__)

  setup do
    elixir = System.find_executable("elixir")

    {:ok, toolset} =
      Toolset.start_link(command: elixir, args: [@mock_server])

    on_exit(fn -> if Process.alive?(toolset), do: Toolset.close(toolset) end)
    %{toolset: toolset}
  end

  describe "start_link/1" do
    test "starts a toolset connected to an MCP server", %{toolset: toolset} do
      assert Process.alive?(toolset)
    end

    test "exits for invalid command" do
      Process.flag(:trap_exit, true)

      assert {:error, _} =
               Toolset.start_link(command: "/nonexistent/binary", args: [])
    end
  end

  describe "get_tools/1" do
    test "returns all tools from the MCP server", %{toolset: toolset} do
      assert {:ok, tools} = Toolset.get_tools(toolset)
      assert length(tools) == 2
      assert Enum.all?(tools, &is_struct(&1, FunctionTool))
      names = Enum.map(tools, & &1.name)
      assert "echo" in names
      assert "add" in names
    end

    test "tools have correct descriptions", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)
      echo = Enum.find(tools, &(&1.name == "echo"))
      assert echo.description == "Echo the input message"

      add = Enum.find(tools, &(&1.name == "add"))
      assert add.description == "Add two numbers"
    end

    test "tools have correct parameter schemas", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)
      echo = Enum.find(tools, &(&1.name == "echo"))
      assert echo.parameters["type"] == "object"
      assert echo.parameters["properties"]["message"]["type"] == "string"
      assert echo.parameters["required"] == ["message"]
    end

    test "calling returned echo tool works", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)
      echo = Enum.find(tools, &(&1.name == "echo"))

      ctx = %ADK.ToolContext{
        context: nil,
        function_call_id: "test-1",
        tool_name: "echo",
        tool_def: nil
      }

      assert {:ok, "hello from MCP"} =
               FunctionTool.run(echo, ctx, %{"message" => "hello from MCP"})
    end

    test "calling returned add tool works", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)
      add = Enum.find(tools, &(&1.name == "add"))

      ctx = %ADK.ToolContext{
        context: nil,
        function_call_id: "test-2",
        tool_name: "add",
        tool_def: nil
      }

      assert {:ok, "10"} = FunctionTool.run(add, ctx, %{"a" => 3, "b" => 7})
    end
  end

  describe "tool_filter" do
    test "filters by name list" do
      elixir = System.find_executable("elixir")

      {:ok, toolset} =
        Toolset.start_link(
          command: elixir,
          args: [@mock_server],
          tool_filter: ["echo"]
        )

      on_exit(fn -> if Process.alive?(toolset), do: Toolset.close(toolset) end)

      assert {:ok, tools} = Toolset.get_tools(toolset)
      assert length(tools) == 1
      assert hd(tools).name == "echo"
    end

    test "filters by predicate function" do
      elixir = System.find_executable("elixir")

      {:ok, toolset} =
        Toolset.start_link(
          command: elixir,
          args: [@mock_server],
          tool_filter: fn tool -> tool.name == "add" end
        )

      on_exit(fn -> if Process.alive?(toolset), do: Toolset.close(toolset) end)

      assert {:ok, tools} = Toolset.get_tools(toolset)
      assert length(tools) == 1
      assert hd(tools).name == "add"
    end

    test "empty filter list returns no tools" do
      elixir = System.find_executable("elixir")

      {:ok, toolset} =
        Toolset.start_link(
          command: elixir,
          args: [@mock_server],
          tool_filter: []
        )

      on_exit(fn -> if Process.alive?(toolset), do: Toolset.close(toolset) end)

      assert {:ok, []} = Toolset.get_tools(toolset)
    end

    test "nil filter returns all tools" do
      elixir = System.find_executable("elixir")

      {:ok, toolset} =
        Toolset.start_link(
          command: elixir,
          args: [@mock_server],
          tool_filter: nil
        )

      on_exit(fn -> if Process.alive?(toolset), do: Toolset.close(toolset) end)

      assert {:ok, tools} = Toolset.get_tools(toolset)
      assert length(tools) == 2
    end
  end

  describe "server_info/1" do
    test "returns server info from initialization", %{toolset: toolset} do
      assert {:ok, info} = Toolset.server_info(toolset)
      assert info["name"] == "MockMCPServer"
      assert info["version"] == "0.1.0"
    end
  end

  describe "get_auth_config/1" do
    test "always returns nil for stdio toolsets", %{toolset: toolset} do
      assert Toolset.get_auth_config(toolset) == nil
    end
  end

  describe "close/1" do
    test "stops the toolset process" do
      elixir = System.find_executable("elixir")
      {:ok, toolset} = Toolset.start_link(command: elixir, args: [@mock_server])

      assert Process.alive?(toolset)
      Toolset.close(toolset)
      refute Process.alive?(toolset)
    end
  end

  describe "tool declarations" do
    test "tools produce valid ADK declarations", %{toolset: toolset} do
      {:ok, tools} = Toolset.get_tools(toolset)
      declarations = Enum.map(tools, &ADK.Tool.declaration/1)

      assert length(declarations) == 2

      Enum.each(declarations, fn decl ->
        assert is_binary(decl.name)
        assert is_binary(decl.description)
        assert is_map(decl.parameters)
      end)
    end
  end
end
