defmodule ADK.OpenClaw.Tools.MemoryBankTest do
  use ExUnit.Case, async: true
  alias ADK.OpenClaw.Tools.MemoryBank
  alias ADK.ToolContext
  alias ADK.Context
  alias ADK.Memory.InMemory

  setup do
    context = %Context{
      app_name: "test_app_#{System.unique_integer([:positive])}",
      user_id: "test_user_#{System.unique_integer([:positive])}",
      memory_store: InMemory
    }

    ctx = %ToolContext{context: context}

    {:ok, %{ctx: ctx}}
  end

  test "write_memory tool adds a fact", %{ctx: ctx} do
    tool = MemoryBank.write_memory()

    assert {:ok, _msg} =
             ADK.Tool.FunctionTool.run(tool, ctx, %{"content" => "OpenClaw is awesome"})

    assert {:ok, entries} =
             InMemory.search(ctx.context.app_name, ctx.context.user_id, "OpenClaw", [])

    assert length(entries) > 0
    assert hd(entries).content == "OpenClaw is awesome"
  end

  test "read_memory tool reads facts and includes id", %{ctx: ctx} do
    entry = %ADK.Memory.Entry{
      id: "123",
      content: "Elixir ADK is fast",
      timestamp: DateTime.utc_now()
    }

    :ok = InMemory.add(ctx.context.app_name, ctx.context.user_id, [entry])

    tool = MemoryBank.read_memory()

    assert {:ok, result} = ADK.Tool.FunctionTool.run(tool, ctx, %{"query" => "fast"})
    assert result =~ "[123] Elixir ADK is fast"
  end

  test "memory_forget tool deletes a fact", %{ctx: ctx} do
    entry = %ADK.Memory.Entry{
      id: "456",
      content: "Delete me",
      timestamp: DateTime.utc_now()
    }

    :ok = InMemory.add(ctx.context.app_name, ctx.context.user_id, [entry])

    tool = MemoryBank.memory_forget()
    assert {:ok, _msg} = ADK.Tool.FunctionTool.run(tool, ctx, %{"memory_id" => "456"})

    # Should not be found
    assert {:ok, []} = InMemory.search(ctx.context.app_name, ctx.context.user_id, "Delete me", [])
  end

  test "memory_correct tool updates a fact", %{ctx: ctx} do
    entry = %ADK.Memory.Entry{
      id: "789",
      content: "Old fact",
      timestamp: DateTime.utc_now()
    }

    :ok = InMemory.add(ctx.context.app_name, ctx.context.user_id, [entry])

    tool = MemoryBank.memory_correct()

    assert {:ok, _msg} =
             ADK.Tool.FunctionTool.run(tool, ctx, %{
               "memory_id" => "789",
               "new_fact" => "New fact"
             })

    assert {:ok, entries} =
             InMemory.search(ctx.context.app_name, ctx.context.user_id, "New fact", [])

    assert length(entries) == 1
    assert hd(entries).content == "New fact"
    assert hd(entries).id == "789"
  end
end
