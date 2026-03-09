defmodule ADK.Tool.FunctionTool do
  @moduledoc """
  Wraps any function as a tool with declaration metadata.

  ## Examples

      tool = ADK.Tool.FunctionTool.new(:greet,
        description: "Greet someone",
        func: fn _ctx, %{"name" => name} -> {:ok, "Hello, \#{name}!"} end,
        parameters: %{
          type: "object",
          properties: %{name: %{type: "string"}},
          required: ["name"]
        }
      )
  """

  defstruct [:name, :description, :func, :parameters]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          func: function(),
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
  def run(%__MODULE__{func: func}, ctx, args) do
    case apply_func(func, ctx, args) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
      {:transfer_to_agent, _} = transfer -> transfer
      other -> {:ok, other}
    end
  end

  defp apply_func(func, ctx, args) when is_function(func, 2), do: func.(ctx, args)
  defp apply_func(func, _ctx, args) when is_function(func, 1), do: func.(args)
end
