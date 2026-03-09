defmodule ADK.Tool.SearchMemoryToolTest do
  use ExUnit.Case, async: false

  alias ADK.Tool.SearchMemoryTool
  alias ADK.Memory.{InMemory, Entry}

  setup do
    InMemory.clear("test_app", "user1")
    :ok
  end

  defp make_tool_context(opts \\ []) do
    memory_store = Keyword.get(opts, :memory_store)

    ctx = %ADK.Context{
      invocation_id: "inv1",
      app_name: "test_app",
      user_id: "user1",
      memory_store: memory_store
    }

    %ADK.ToolContext{
      context: ctx,
      function_call_id: "fc1",
      tool_name: "search_memory"
    }
  end

  test "name/0 returns search_memory" do
    assert SearchMemoryTool.name() == "search_memory"
  end

  test "parameters/0 returns valid schema" do
    params = SearchMemoryTool.parameters()
    assert params.properties.query.type == "string"
  end

  test "returns error when no memory store configured" do
    tc = make_tool_context()
    assert {:error, "No memory store configured"} =
             SearchMemoryTool.run(tc, %{"query" => "test"})
  end

  test "searches memory and returns formatted results" do
    InMemory.add("test_app", "user1", [
      Entry.new(content: "User loves Elixir programming", author: "assistant")
    ])

    tc = make_tool_context(memory_store: {InMemory, []})
    assert {:ok, result} = SearchMemoryTool.run(tc, %{"query" => "Elixir"})
    assert result =~ "Elixir programming"
    assert result =~ "[assistant]"
  end

  test "returns message when no memories found" do
    tc = make_tool_context(memory_store: {InMemory, []})
    assert {:ok, "No relevant memories found."} =
             SearchMemoryTool.run(tc, %{"query" => "nonexistent"})
  end

  test "returns error for empty query" do
    tc = make_tool_context(memory_store: {InMemory, []})
    assert {:error, "Query cannot be empty"} =
             SearchMemoryTool.run(tc, %{"query" => ""})
  end
end
