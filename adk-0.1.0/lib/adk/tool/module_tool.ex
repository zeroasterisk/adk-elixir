defmodule ADK.Tool.ModuleTool do
  @moduledoc """
  A tool backed by a module instead of an anonymous function.

  This solves the problem of tools with anonymous functions not being
  usable in compile-time Plug config (e.g., `plug MyPlug, tools: [...]`).

  ## Usage

  Define a module implementing `ADK.Tool`:

      defmodule MyTool do
        @behaviour ADK.Tool

        @impl true
        def name, do: "my_tool"

        @impl true
        def description, do: "Does something useful"

        @impl true
        def parameters, do: %{type: "object", properties: %{input: %{type: "string"}}}

        @impl true
        def run(_ctx, args), do: {:ok, "Got: \#{args["input"]}"}
      end

  Then wrap it:

      tool = ADK.Tool.ModuleTool.new(MyTool)

  Or use it directly — any module implementing `ADK.Tool` can be used
  as a tool struct via `ADK.Tool.ModuleTool.new/1`.
  """

  defstruct [:module, :name, :description, :parameters]

  @type t :: %__MODULE__{
          module: module(),
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @doc "Create a tool struct from a module implementing `ADK.Tool`."
  @spec new(module(), keyword()) :: t()
  def new(module, opts \\ []) do
    %__MODULE__{
      module: module,
      name: opts[:name] || module.name(),
      description: opts[:description] || module.description(),
      parameters: opts[:parameters] || if(function_exported?(module, :parameters, 0), do: module.parameters(), else: %{})
    }
  end

  @doc "Execute the module tool."
  @spec run(t(), ADK.ToolContext.t(), map()) :: ADK.Tool.result()
  def run(%__MODULE__{module: module}, ctx, args) do
    case module.run(ctx, args) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
      other -> {:ok, other}
    end
  end
end
