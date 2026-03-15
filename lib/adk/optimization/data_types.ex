defmodule ADK.Optimization.DataTypes do
  @moduledoc """
  Data types used in agent prompt optimization.
  """

  defmodule BaseSamplingResult do
    @moduledoc "Base class for evaluation results."
    @enforce_keys [:scores]
    defstruct [:scores]
  end

  defmodule UnstructuredSamplingResult do
    @moduledoc "Evaluation result providing per-example unstructured evaluation data."
    @enforce_keys [:scores]
    defstruct [:scores, :data]
  end

  defmodule BaseAgentWithScores do
    @moduledoc "An optimized agent with its scores."
    @enforce_keys [:optimized_agent]
    defstruct [:optimized_agent, :overall_score]
  end

  defmodule OptimizerResult do
    @moduledoc "Base class for optimizer final results."
    @enforce_keys [:optimized_agents]
    defstruct [:optimized_agents]
  end
end
