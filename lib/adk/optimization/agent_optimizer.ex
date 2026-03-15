defmodule ADK.Optimization.AgentOptimizer do
  @moduledoc """
  Base behaviour for agent optimizers.
  """

  @callback optimize(
    optimizer :: struct(),
    initial_agent :: struct(),
    sampler :: struct()
  ) :: {:ok, struct()} | {:error, term()}
end
