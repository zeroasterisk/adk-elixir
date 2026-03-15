defmodule ADK.Optimization.Sampler do
  @moduledoc """
  Base behaviour for agent optimizers to sample and score candidate agents.
  """

  @type example_set :: :train | :validation

  @callback get_train_example_ids(sampler :: struct()) :: [String.t()]
  @callback get_validation_example_ids(sampler :: struct()) :: [String.t()]

  @callback sample_and_score(
    sampler :: struct(),
    candidate :: struct(),
    example_set :: example_set(),
    batch :: [String.t()] | nil,
    capture_full_eval_data :: boolean()
  ) :: struct()
end
