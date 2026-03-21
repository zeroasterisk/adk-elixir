defmodule ADK.Workflow.Step do
  @moduledoc """
  Represents a single workflow step with support for execution and compensation.
  """
  @enforce_keys [:name, :run]
  defstruct [:name, :run, :compensate]

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          run: (any() -> any()) | (any(), any() -> any()),
          compensate: (any(), any(), any() -> any()) | nil
        }

  @doc """
  Create a new step with a run function and optional compensation function.
  """
  def new(name, run_fun, compensate_fun \\ nil) do
    %__MODULE__{
      name: name,
      run: run_fun,
      compensate: compensate_fun
    }
  end
end

defimpl ADK.Agent, for: ADK.Workflow.Step do
  def name(step), do: to_string(step.name)
  def description(_), do: "Workflow Step"
  def sub_agents(_), do: []

  def run(step, ctx) do
    # When executed as an agent directly, just run the run_fun
    result =
      if is_function(step.run, 2) do
        step.run.(step.name, ctx)
      else
        step.run.(ctx)
      end

    case result do
      {:error, reason} ->
        [ADK.Event.error(inspect(reason), author: to_string(step.name))]

      events when is_list(events) ->
        events

      other ->
        [
          ADK.Event.new(
            author: to_string(step.name),
            content: %{"parts" => [%{"text" => inspect(other)}]}
          )
        ]
    end
  end
end
