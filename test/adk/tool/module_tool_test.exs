defmodule ADK.Tool.ModuleToolTest do
  use ExUnit.Case, async: true

  defmodule GreetTool do
    @behaviour ADK.Tool

    @impl true
    def name, do: "greet"

    @impl true
    def description, do: "Greet someone by name"

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{name: %{type: "string"}},
        required: ["name"]
      }
    end

    @impl true
    def run(_ctx, %{"name" => name}), do: {:ok, "Hello, #{name}!"}
  end

  test "new/1 creates a module tool from a behaviour module" do
    tool = ADK.Tool.ModuleTool.new(GreetTool)
    assert tool.name == "greet"
    assert tool.description == "Greet someone by name"
    assert tool.parameters.type == "object"
    assert tool.module == GreetTool
  end

  test "run/3 delegates to the module" do
    tool = ADK.Tool.ModuleTool.new(GreetTool)
    ctx = ADK.ToolContext.new(%ADK.Context{invocation_id: "test"}, "c1", tool)
    assert {:ok, "Hello, World!"} = ADK.Tool.ModuleTool.run(tool, ctx, %{"name" => "World"})
  end

  test "declaration/1 works with ModuleTool" do
    tool = ADK.Tool.ModuleTool.new(GreetTool)
    decl = ADK.Tool.declaration(tool)
    assert decl.name == "greet"
    assert decl.description == "Greet someone by name"
  end

  test "module tool is serializable (no closures)" do
    tool = ADK.Tool.ModuleTool.new(GreetTool)
    # Should be inspectable and reconstructable without closures
    assert is_atom(tool.module)
    assert tool.module == GreetTool
  end
end
