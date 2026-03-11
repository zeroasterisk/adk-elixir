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

  @doc """
  Check if a tool is a Gemini built-in (google_search, code_execution, etc).

  Built-in tools are sent to the Gemini API as native capability flags rather
  than function declarations.
  """
  @spec builtin?(map()) :: boolean()
  def builtin?(%{__builtin__: _}), do: true
  def builtin?(_), do: false

  @doc "Build a function declaration from a tool struct."
  @spec declaration(map()) :: map()
  # Built-in tools carry the marker through for backend routing
  def declaration(%{__builtin__: builtin, name: name, description: desc}) do
    %{name: name, description: desc, parameters: %{}, __builtin__: builtin}
  end

  def declaration(%{name: name, description: desc, parameters: params}) do
    %{name: name, description: desc, parameters: params}
  end

  def declaration(%{name: name, description: desc}) do
    %{name: name, description: desc, parameters: %{}}
  end
end
