defmodule ADK.Optimization.SimplePromptOptimizerTest do
  use ExUnit.Case
  alias ADK.Optimization.SimplePromptOptimizer

  # Mock Sampler for testing
  defmodule MockSampler do
    defstruct []
    def get_train_example_ids(_sampler), do: ["1", "2", "3"]
    def get_validation_example_ids(_sampler), do: ["4"]
    def sample_and_score(_sampler, _agent, _set, _ids, _capture) do
      %ADK.Optimization.DataTypes.UnstructuredSamplingResult{
        scores: %{"1" => 0.5, "2" => 0.6, "3" => 0.7}
      }
    end
  end

  test "optimize/3 runs successfully" do
    sampler = %MockSampler{}
    agent = %{instruction: "Do something"}
    optimizer = SimplePromptOptimizer.new(num_iterations: 1, batch_size: 2)
    
    {:ok, result} = SimplePromptOptimizer.optimize(optimizer, agent, sampler)
    
    assert length(result.optimized_agents) == 1
    assert result.optimized_agents |> hd() |> Map.get(:overall_score) >= 0.0
  end
end
