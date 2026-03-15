defmodule ADK.CodeExecutor do
  @moduledoc """
  Abstract behaviour for all code executors.

  The code executor allows the agent to execute code blocks from model responses
  and incorporate the execution results into the final response.
  """

  defmodule File do
    @moduledoc """
    Represents a file used in code execution.
    """
    @type t :: %__MODULE__{
            name: String.t(),
            content: binary(),
            mime_type: String.t() | nil
          }
    @enforce_keys [:name, :content]
    defstruct [:name, :content, :mime_type]
  end

  defmodule Input do
    @moduledoc """
    Input for code execution.
    """
    @type t :: %__MODULE__{
            code: String.t(),
            execution_id: String.t() | nil,
            input_files: [ADK.CodeExecutor.File.t()] | nil
          }
    @enforce_keys [:code]
    defstruct [:code, :execution_id, input_files: []]
  end

  defmodule Result do
    @moduledoc """
    Result of code execution.
    """
    @type t :: %__MODULE__{
            stdout: String.t(),
            stderr: String.t(),
            output_files: [ADK.CodeExecutor.File.t()] | nil
          }
    defstruct stdout: "", stderr: "", output_files: []
  end

  @doc """
  Executes code and returns the code execution result.
  """
  @callback execute_code(
              executor :: struct(),
              invocation_context :: map() | nil,
              input :: Input.t()
            ) :: Result.t() | {:error, any()}
end
