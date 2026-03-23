defmodule ADK.Tool.Declarative do
  @moduledoc """
  Macro-based tool declaration using `@tool` module attributes.

  ## Usage

      defmodule MyTools do
        use ADK.Tool.Declarative

        @tool name: "greet", description: "Greet a person"
        def greet(_ctx, %{"name" => name}) do
          {:ok, "Hello, \#{name}!"}
        end

        @tool name: "add", description: "Add two numbers"
        def add(_ctx, %{"a" => a, "b" => b}) do
          {:ok, a + b}
        end
      end

      MyTools.__tools__()
      # => [%ADK.Tool.FunctionTool{name: "greet", ...}, ...]
  """

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :tool, [])
      Module.register_attribute(__MODULE__, :__adk_tools, accumulate: true)
      @on_definition ADK.Tool.Declarative
      @before_compile ADK.Tool.Declarative
    end
  end

  @doc false
  @spec __on_definition__(Macro.Env.t(), atom(), atom(), list(), list(), term()) :: :ok
  def __on_definition__(env, :def, name, _args, _guards, _body) do
    case Module.get_attribute(env.module, :tool) do
      nil ->
        :ok

      opts when is_list(opts) ->
        tool_entry = {name, opts}
        Module.put_attribute(env.module, :__adk_tools, tool_entry)
        Module.delete_attribute(env.module, :tool)
        Module.register_attribute(env.module, :tool, [])
        :ok
    end
  end

  @doc false
  @spec __on_definition__(Macro.Env.t(), atom(), atom(), list(), list(), term()) :: :ok
  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  defmacro __before_compile__(env) do
    tools = Module.get_attribute(env.module, :__adk_tools) |> Enum.reverse()

    tool_defs =
      Enum.map(tools, fn {func_name, opts} ->
        name = Keyword.get(opts, :name, to_string(func_name))
        desc = Keyword.get(opts, :description, "")

        quote do
          %ADK.Tool.FunctionTool{
            name: unquote(name),
            description: unquote(desc),
            func: &__MODULE__.unquote(func_name) / 2,
            parameters: %{}
          }
        end
      end)

    quote do
      def __tools__ do
        unquote(tool_defs)
      end
    end
  end
end
