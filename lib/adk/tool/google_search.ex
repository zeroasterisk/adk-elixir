defmodule ADK.Tool.GoogleSearch do
  @moduledoc """
  Built-in Google Search tool for Gemini models.

  When this tool is added to an `LlmAgent`, ADK Elixir signals the Gemini
  backend to enable native Google Search grounding instead of using a
  function declaration. The LLM can then call Google Search directly and
  include grounded citations in its response.

  This mirrors the Python ADK `google_search` built-in tool.

  ## Usage

      agent = ADK.Agent.LlmAgent.new(
        name: "researcher",
        model: "gemini-flash-latest",
        instruction: "Answer questions with up-to-date information.",
        tools: [ADK.Tool.GoogleSearch.new()]
      )

  ## Notes

  - Only supported on Gemini backends (Gemini 2.0+).
  - Cannot be combined with `function_declarations` in the same request
    (Gemini API restriction). Use `code_execution` alongside if needed.
  - On non-Gemini backends, `run/2` returns an error.
  """

  @builtin :google_search

  defstruct name: "google_search",
            description: "Google Search built-in tool for grounded, up-to-date answers.",
            __builtin__: @builtin

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          __builtin__: :google_search
        }

  @doc "Create a GoogleSearch built-in tool instance."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Stub run — this tool is executed natively by the Gemini backend.

  Returns an error when called directly (it should never be invoked via the
  tool-call loop; Gemini handles it transparently).
  """
  @spec run(ADK.ToolContext.t(), map()) :: ADK.Tool.result()
  def run(_ctx, _args) do
    {:error, "GoogleSearch is a built-in Gemini tool and cannot be called directly."}
  end
end
