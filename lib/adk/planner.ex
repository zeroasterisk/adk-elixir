defmodule ADK.Planner do
  @moduledoc """
  Behaviour for Agent Planners.

  Planners allow an agent to generate plans for queries to guide its actions.
  """

  @doc """
  Builds the system instruction to be appended to the LLM request for planning.
  """
  @callback build_planning_instruction(ctx :: ADK.Context.t(), request :: map()) :: String.t() | nil

  @doc """
  Processes the LLM response for planning, extracting/modifying parts.
  """
  @callback process_planning_response(ctx :: ADK.Context.t(), parts :: list(map())) :: list(map()) | nil
end
