defmodule ADK.Eval.Case do
  @moduledoc """
  Defines a single evaluation test case.

  A case specifies an input message to send to an agent, a list of scorers
  to evaluate the response, and optional metadata.

  ## Example

      ADK.Eval.Case.new(
        name: "greeting",
        input: "Hello!",
        scorers: [
          {ADK.Eval.Scorer.Contains, text: "hello", case_sensitive: false},
          {ADK.Eval.Scorer.ResponseLength, min: 5, max: 200}
        ],
        metadata: %{category: "basic"}
      )
  """

  @type scorer_config :: {module(), keyword()}

  @type t :: %__MODULE__{
          name: String.t(),
          input: String.t(),
          scorers: [scorer_config()],
          metadata: map()
        }

  defstruct [:name, :input, scorers: [], metadata: %{}]

  @doc "Create a new eval case."
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      input: Keyword.fetch!(opts, :input),
      scorers: Keyword.get(opts, :scorers, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
