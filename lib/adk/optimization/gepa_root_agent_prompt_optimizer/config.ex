defmodule ADK.Optimization.GepaRootAgentPromptOptimizer.Config do
  @moduledoc """
  Configuration for GepaRootAgentPromptOptimizer.
  """

  @type t :: %__MODULE__{
          optimizer_model: String.t(),
          model_configuration: map(),
          max_metric_calls: integer(),
          reflection_minibatch_size: integer(),
          run_dir: String.t() | nil
        }

  defstruct [
    optimizer_model: "gemini-2.0-flash",
    model_configuration: %{
      "thinking_config" => %{
        "include_thoughts" => true,
        "thinking_budget" => 10240
      }
    },
    max_metric_calls: 100,
    reflection_minibatch_size: 3,
    run_dir: nil
  ]

  @doc "Create a new config."
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end
end
