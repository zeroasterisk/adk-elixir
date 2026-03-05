defmodule ADK.Tool do
  @moduledoc """
  The tool behaviour. Tools are functions that agents can call.
  """

  @type result :: {:ok, term()} | {:error, term()}

  @doc "Tool name for LLM function calling."
  @callback name() :: String.t()

  @doc "Human-readable description."
  @callback description() :: String.t()

  @doc "JSON Schema for parameters."
  @callback parameters() :: map()

  @doc "Execute the tool."
  @callback run(ctx :: ADK.ToolContext.t(), args :: map()) :: result()

  @optional_callbacks [parameters: 0]

  @doc "Build a function declaration from a tool struct."
  @spec declaration(map()) :: map()
  def declaration(%{name: name, description: desc, parameters: params}) do
    %{name: name, description: desc, parameters: params}
  end

  def declaration(%{name: name, description: desc}) do
    %{name: name, description: desc, parameters: %{}}
  end
end
