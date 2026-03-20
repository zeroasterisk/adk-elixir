defmodule ADK.MCP.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.FunctionTool

  @mock_server Path.expand("../../../../priv/test_scripts/mock_mcp_server.exs", __DIR__)

  setup do
    elixir = System.find_executable("elixir")
    {:ok, client} = ADK.MCP.Client.start_link(command: elixir, args: [@mock_server])
    on_exit(fn -> if Process.alive?(client), do: ADK.MCP.Client.close(client) end)
    %{client: client}
  end

  test "converts MCP tools to ADK FunctionTools", %{client: client} do
    assert {:ok, tools} = ADK.MCP.ToolAdapter.to_adk_tools(client)
    assert length(tools) == 2
    assert Enum.all?(tools, &is_struct(&1, FunctionTool))

    echo = Enum.find(tools, &(&1.name == "echo"))
    assert echo.description == "Echo the input message"
    assert echo.parameters["type"] == "object"
  end

  test "ADK tools produce correct declarations", %{client: client} do
    {:ok, tools} = ADK.MCP.ToolAdapter.to_adk_tools(client)
    declarations = Enum.map(tools, &ADK.Tool.declaration/1)
    names = Enum.map(declarations, & &1.name)
    assert "echo" in names
    assert "add" in names
  end

  test "calling adapted echo tool works", %{client: client} do
    {:ok, tools} = ADK.MCP.ToolAdapter.to_adk_tools(client)
    echo = Enum.find(tools, &(&1.name == "echo"))

    ctx = %ADK.ToolContext{context: nil, function_call_id: "1", tool_name: "echo", tool_def: nil}
    assert {:ok, "hello world"} = FunctionTool.run(echo, ctx, %{"message" => "hello world"})
  end

  test "calling adapted add tool works", %{client: client} do
    {:ok, tools} = ADK.MCP.ToolAdapter.to_adk_tools(client)
    add = Enum.find(tools, &(&1.name == "add"))

    ctx = %ADK.ToolContext{context: nil, function_call_id: "1", tool_name: "add", tool_def: nil}
    assert {:ok, "7"} = FunctionTool.run(add, ctx, %{"a" => 3, "b" => 4})
  end
end
