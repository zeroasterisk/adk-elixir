defmodule ADK.CodeExecutor.UnsafeLocal do
  @moduledoc """
  An unsafe local code executor that evaluates Elixir code directly within the
  running BEAM process.

  WARNING: This provides the LLM with full arbitrary code execution access to
  the host environment. Use only in controlled local development setups.

  Matches the spirit of Python's `UnsafeLocalCodeExecutor` but native to Elixir.
  """
  @behaviour ADK.CodeExecutor

  defstruct []

  @impl true
  def execute_code(_executor, _invocation_context, %ADK.CodeExecutor.Input{code: code}) do
    try do
      {result, _bindings} = Code.eval_string(code)
      %ADK.CodeExecutor.Result{
        stdout: inspect(result),
        stderr: ""
      }
    rescue
      e ->
        %ADK.CodeExecutor.Result{
          stdout: "",
          stderr: Exception.format(:error, e, __STACKTRACE__)
        }
    end
  end
end
