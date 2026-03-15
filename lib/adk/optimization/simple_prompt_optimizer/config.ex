defmodule ADK.Optimization.SimplePromptOptimizer.Config do
  @moduledoc """
  Configuration for SimplePromptOptimizer.
  """

  @type t :: %__MODULE__{
          optimizer_model: String.t(),
          model_configuration: map(),
          num_iterations: integer(),
          batch_size: integer()
        }

  defstruct [
    optimizer_model: "gemini-2.0-flash",
    model_configuration: %{
      "thinking_config" => %{
        "include_thoughts" => true,
        "thinking_budget" => 10240
      }
    },
    num_iterations: 10,
    batch_size: 5
  ]

  @doc "Create a new config."
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end
end
