defmodule ADK.Tool.BuiltInCodeExecution do
  @moduledoc """
  Built-in Code Execution tool for Gemini models.

  When added to an `LlmAgent`, this signals the Gemini backend to enable
  native code execution. The LLM can write and run Python code in a sandboxed
  environment and return results, without requiring a custom tool implementation.

  This mirrors the Python ADK `built_in_code_execution` built-in tool.

  ## Usage

      agent = ADK.Agent.LlmAgent.new(
        name: "coder",
        model: "gemini-2.0-flash",
        instruction: "Solve math problems by writing and running Python code.",
        tools: [ADK.Tool.BuiltInCodeExecution.new()]
      )

  ## Notes

  - Only supported on Gemini 2.0+ backends.
  - Cannot be combined with `function_declarations` (Gemini API restriction).
  - On non-Gemini backends, `run/2` returns an error.
  - Code execution responses include `executable_code` and
    `code_execution_result` parts in the model response.
  """

  @builtin :code_execution

  defstruct name: "code_execution",
            description: "Built-in code execution tool — allows the model to run Python code.",
            __builtin__: @builtin

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          __builtin__: :code_execution
        }

  @doc "Create a BuiltInCodeExecution tool instance."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Stub run — this tool is executed natively by the Gemini backend.

  Returns an error when called directly; Gemini handles it transparently.
  """
  @spec run(ADK.ToolContext.t(), map()) :: ADK.Tool.result()
  def run(_ctx, _args) do
    {:error, "BuiltInCodeExecution is a built-in Gemini tool and cannot be called directly."}
  end
end
