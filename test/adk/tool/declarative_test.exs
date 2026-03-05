defmodule ADK.Tool.DeclarativeTestTools do
  use ADK.Tool.Declarative

  @tool name: "greet", description: "Greet a person"
  def greet(_ctx, %{"name" => name}) do
    {:ok, "Hello, #{name}!"}
  end

  @tool name: "add", description: "Add two numbers"
  def add(_ctx, %{"a" => a, "b" => b}) do
    {:ok, a + b}
  end
end

defmodule ADK.Tool.DeclarativeTest do
  use ExUnit.Case, async: true

  test "__tools__ returns list of FunctionTool structs" do
    tools = ADK.Tool.DeclarativeTestTools.__tools__()
    assert length(tools) == 2

    [greet, add] = tools
    assert %ADK.Tool.FunctionTool{name: "greet", description: "Greet a person"} = greet
    assert %ADK.Tool.FunctionTool{name: "add", description: "Add two numbers"} = add
  end

  test "declared tools are callable" do
    [greet | _] = ADK.Tool.DeclarativeTestTools.__tools__()

    ctx = %ADK.ToolContext{
      context: %ADK.Context{invocation_id: "inv-1"},
      function_call_id: "call-1",
      tool_name: "greet",
      tool_def: greet
    }

    assert {:ok, "Hello, World!"} = ADK.Tool.FunctionTool.run(greet, ctx, %{"name" => "World"})
  end
end
