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

  @doc """
  Auto-wraps a function or MFA tuple into a `FunctionTool`.
  """
  @spec wrap(function() | {module(), atom()} | {module(), atom(), list()}) :: ADK.Tool.FunctionTool.t()
  def wrap(func) when is_function(func) do
    info = Function.info(func)
    name = info[:name] |> to_string()
    
    # Handle anonymous function names like "-do_run/3-fun-0-"
    name = if String.starts_with?(name, "-"), do: "anonymous_tool", else: name

    ADK.Tool.FunctionTool.new(name,
      description: "Auto-wrapped function",
      func: func,
      parameters: %{}
    )
  end

  def wrap({mod, fun} = mfa) when is_atom(mod) and is_atom(fun) do
    ADK.Tool.FunctionTool.new(to_string(fun),
      description: "Auto-wrapped function",
      func: mfa,
      parameters: %{}
    )
  end

  def wrap({mod, fun, extra} = mfa) when is_atom(mod) and is_atom(fun) and is_list(extra) do
    ADK.Tool.FunctionTool.new(to_string(fun),
      description: "Auto-wrapped function",
      func: mfa,
      parameters: %{}
    )
  end
end
