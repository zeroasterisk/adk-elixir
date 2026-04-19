defmodule ADK.Tool.FunctionTool do
  @moduledoc """
  Wraps any function as a tool with declaration metadata.

  The `func` field accepts:

  - An anonymous function (arity 1 or 2) — for runtime use
  - An MFA tuple `{Module, :function, extra_args}` — compile-time safe
  - A plain MF tuple `{Module, :function}` — shorthand for `{Module, :function, []}`

  MFA tuples are called as `Module.function(ctx, args, ...extra_args)` (arity 2+)
  or `Module.function(args, ...extra_args)` if the function has no context parameter.

  ## Examples

      # Anonymous function (runtime only)
      tool = ADK.Tool.FunctionTool.new(:greet,
        description: "Greet someone",
        func: fn _ctx, %{"name" => name} -> {:ok, "Hello, \#{name}!"} end,
        parameters: %{
          type: "object",
          properties: %{name: %{type: "string"}},
          required: ["name"]
        }
      )

      # MFA tuple (compile-time safe, works in Plug init/1)
      tool = ADK.Tool.FunctionTool.new(:greet,
        description: "Greet someone",
        func: {MyApp.Tools, :greet},
        parameters: %{
          type: "object",
          properties: %{name: %{type: "string"}},
          required: ["name"]
        }
      )
  """

  defstruct [:name, :description, :func, :parameters]

  @type mfa_tuple :: {module(), atom(), list()} | {module(), atom()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          func: function() | mfa_tuple(),
          parameters: map()
        }

  @doc "Create a new function tool."
  @spec new(atom() | String.t(), keyword()) :: t()
  def new(name, opts) do
    %__MODULE__{
      name: to_string(name),
      description: opts[:description] || "",
      func: opts[:func],
      parameters: opts[:parameters] || %{}
    }
  end

  @doc "Execute the function tool."
  @spec run(t(), ADK.ToolContext.t(), map()) :: ADK.Tool.result()
  def run(%__MODULE__{func: func, name: name}, ctx, args) do
    case apply_func(func, ctx, args) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
      {:transfer_to_agent, _} = transfer -> transfer
      {:exit_loop, _} = exit -> exit
      other -> {:ok, other}
    end
  rescue
    e ->
      {:error, "Tool #{name} execution failed with exception: #{Exception.message(e)}"}
  end

  defp apply_func(func, ctx, args) when is_function(func, 2), do: func.(ctx, args)
  defp apply_func(func, _ctx, args) when is_function(func, 1), do: func.(args)

  defp apply_func({mod, fun}, ctx, args) when is_atom(mod) and is_atom(fun),
    do: apply(mod, fun, [ctx, args])

  defp apply_func({mod, fun, extra}, ctx, args)
       when is_atom(mod) and is_atom(fun) and is_list(extra),
       do: apply(mod, fun, [ctx, args | extra])
end
