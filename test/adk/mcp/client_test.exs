defmodule ADK.MCP.ClientTest do
  use ExUnit.Case, async: true

  @mock_server Path.expand("../../../priv/test_scripts/mock_mcp_server.exs", __DIR__)

  setup do
    elixir = System.find_executable("elixir")
    {:ok, client} = ADK.MCP.Client.start_link(command: elixir, args: [@mock_server])
    on_exit(fn ->
      try do
        if Process.alive?(client), do: ADK.MCP.Client.close(client)
      catch
        :exit, _ -> :ok
      end
    end)
    %{client: client}
  end

  test "initializes and reports server info", %{client: client} do
    assert {:ok, info} = ADK.MCP.Client.server_info(client)
    assert info["name"] == "MockMCPServer"
  end

  test "lists tools", %{client: client} do
    assert {:ok, %{"tools" => tools}} = ADK.MCP.Client.list_tools(client)
    assert length(tools) == 2
    names = Enum.map(tools, & &1["name"])
    assert "echo" in names
    assert "add" in names
  end

  test "calls echo tool", %{client: client} do
    assert {:ok, result} = ADK.MCP.Client.call_tool(client, "echo", %{"message" => "hello"})
    assert result["content"] == [%{"type" => "text", "text" => "hello"}]
  end

  test "calls add tool", %{client: client} do
    assert {:ok, result} = ADK.MCP.Client.call_tool(client, "add", %{"a" => 3, "b" => 4})
    assert result["content"] == [%{"type" => "text", "text" => "7"}]
  end

  test "unknown tool returns error", %{client: client} do
    assert {:error, %{"code" => -32601}} = ADK.MCP.Client.call_tool(client, "nonexistent", %{})
  end
end
