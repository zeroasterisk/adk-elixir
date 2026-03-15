defmodule ADK.Optimization.LocalEvalSampler do
  @moduledoc """
  Evaluates candidate agents with the ADK's Eval framework.
  """
  
  @behaviour ADK.Optimization.Sampler

  alias ADK.Eval
  alias ADK.Optimization.DataTypes.UnstructuredSamplingResult

  defstruct [
    :runner,
    :train_cases,
    :validation_cases,
    :train_ids,
    :validation_ids
  ]

  def new(runner, train_cases, validation_cases) do
    %__MODULE__{
      runner: runner,
      train_cases: train_cases,
      validation_cases: validation_cases,
      train_ids: Enum.map(train_cases, & &1.name),
      validation_ids: Enum.map(validation_cases, & &1.name)
    }
  end

  @impl true
  def get_train_example_ids(sampler), do: sampler.train_ids

  @impl true
  def get_validation_example_ids(sampler), do: sampler.validation_ids

  @impl true
  def sample_and_score(sampler, candidate, example_set, batch, _capture_full_eval_data) do
    # Create a new runner for the candidate
    new_runner = %{sampler.runner | agent: candidate}
    
    # Filter cases if batch is provided
    cases = case example_set do
      :train -> sampler.train_cases
      :validation -> sampler.validation_cases
    end
    
    target_cases = if batch, do: Enum.filter(cases, &(&1.name in batch)), else: cases
    
    # Run evaluation
    report = ADK.Eval.run(new_runner, target_cases)
    
    scores = Enum.map(report.results, &({&1.case_name, &1.aggregate_score})) |> Map.new()
    
    %UnstructuredSamplingResult{scores: scores, data: %{}}
  end
end
