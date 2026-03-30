defmodule ADK.Tool.FunctionToolTest do
  use ExUnit.Case, async: true

  test "new creates a tool struct" do
    tool =
      ADK.Tool.FunctionTool.new(:greet,
        description: "Greet someone",
        func: fn _ctx, %{"name" => name} -> {:ok, "Hello, #{name}!"} end,
        parameters: %{type: "object", properties: %{name: %{type: "string"}}}
      )

    assert tool.name == "greet"
    assert tool.description == "Greet someone"
    assert is_function(tool.func)
  end

  test "run executes the function with context" do
    tool =
      ADK.Tool.FunctionTool.new(:greet,
        func: fn _ctx, %{"name" => name} -> {:ok, "Hello, #{name}!"} end
      )

    ctx = %ADK.ToolContext{
      context: %ADK.Context{invocation_id: "inv-1"},
      function_call_id: "call-1",
      tool_name: "greet",
      tool_def: tool
    }

    assert {:ok, "Hello, World!"} = ADK.Tool.FunctionTool.run(tool, ctx, %{"name" => "World"})
  end

  test "run wraps bare return values" do
    tool = ADK.Tool.FunctionTool.new(:count, func: fn _ctx, _args -> 42 end)

    ctx = %ADK.ToolContext{
      context: %ADK.Context{invocation_id: "inv-1"},
      function_call_id: "call-1",
      tool_name: "count",
      tool_def: tool
    }

    assert {:ok, 42} = ADK.Tool.FunctionTool.run(tool, ctx, %{})
  end

  test "run with arity-1 function" do
    tool = ADK.Tool.FunctionTool.new(:echo, func: fn args -> {:ok, args} end)

    ctx = %ADK.ToolContext{
      context: %ADK.Context{invocation_id: "inv-1"},
      function_call_id: "call-1",
      tool_name: "echo",
      tool_def: tool
    }

    assert {:ok, %{"x" => 1}} = ADK.Tool.FunctionTool.run(tool, ctx, %{"x" => 1})
  end

  test "run with MF tuple (compile-time safe)" do
    tool = ADK.Tool.FunctionTool.new(:greet, func: {ADK.Tool.FunctionToolTest.Helpers, :greet})

    ctx = %ADK.ToolContext{
      context: %ADK.Context{invocation_id: "inv-1"},
      function_call_id: "call-1",
      tool_name: "greet",
      tool_def: tool
    }

    assert {:ok, "Hello, Alice!"} = ADK.Tool.FunctionTool.run(tool, ctx, %{"name" => "Alice"})
  end

  test "run with MFA tuple with extra args" do
    tool =
      ADK.Tool.FunctionTool.new(:greet,
        func: {ADK.Tool.FunctionToolTest.Helpers, :greet_with_prefix, ["Dr."]}
      )

    ctx = %ADK.ToolContext{
      context: %ADK.Context{invocation_id: "inv-1"},
      function_call_id: "call-1",
      tool_name: "greet",
      tool_def: tool
    }

    assert {:ok, "Hello, Dr. Bob!"} = ADK.Tool.FunctionTool.run(tool, ctx, %{"name" => "Bob"})
  end

  test "MFA tuple is serializable (compile-time safe)" do
    # MFA tuples can be stored in module attributes, unlike anonymous fns
    tool =
      ADK.Tool.FunctionTool.new(:greet,
        description: "Greet someone",
        func: {ADK.Tool.FunctionToolTest.Helpers, :greet},
        parameters: %{type: "object"}
      )

    # Verify the func field is a tuple (serializable), not a function (not serializable)
    assert is_tuple(tool.func)
    assert {ADK.Tool.FunctionToolTest.Helpers, :greet} = tool.func
  end

  test "declaration generates tool metadata" do
    tool =
      ADK.Tool.FunctionTool.new(:search,
        description: "Search the web",
        func: fn _, _ -> {:ok, []} end,
        parameters: %{type: "object"}
      )

    decl = ADK.Tool.declaration(tool)
    assert decl.name == "search"
    assert decl.description == "Search the web"
    assert decl.parameters == %{type: "object"}
  end

  defmodule Helpers do
    def greet(_ctx, %{"name" => name}), do: {:ok, "Hello, #{name}!"}
    def greet_with_prefix(_ctx, %{"name" => name}, prefix), do: {:ok, "Hello, #{prefix} #{name}!"}
  end
end
