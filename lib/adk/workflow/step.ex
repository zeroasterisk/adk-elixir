defmodule ADK.Workflow.Step do
  @moduledoc """
  Represents a single workflow step with support for execution and compensation.
  """
  @enforce_keys [:name, :run]
  defstruct [:name, :run, :compensate, :validate, retry_times: 0, backoff: :exponential]

  @type backoff :: :exponential | :linear | pos_integer()

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          run: (any() -> any()) | (any(), any() -> any()),
          compensate: (any(), any(), any() -> any()) | nil,
          validate:
            (any(), any() -> :ok | {:error, any()}) | (any() -> :ok | {:error, any()}) | nil,
          retry_times: non_neg_integer(),
          backoff: backoff()
        }

  @doc """
  Create a new step with a run function and optional compensation function.

  ## Options

  - `:compensate` — compensation function for saga rollback
  - `:validate` — validation function for output
  - `:retry_times` — max retry attempts on failure (default: 0)
  - `:backoff` — backoff strategy: `:exponential`, `:linear`, or fixed ms (default: `:exponential`)
  """
  def new(name, run_fun, compensate_fun \\ nil, validate_fun \\ nil) do
    %__MODULE__{
      name: name,
      run: run_fun,
      compensate: compensate_fun,
      validate: validate_fun
    }
  end

  @doc """
  Create a new step with keyword options for full configuration.

  ## Examples

      Step.new_with_opts(:fetch, &fetch/1, retry_times: 3, backoff: :exponential)
      Step.new_with_opts(:save, &save/1, retry_times: 2, backoff: 500)
  """
  def new_with_opts(name, run_fun, opts \\ []) do
    %__MODULE__{
      name: name,
      run: run_fun,
      compensate: Keyword.get(opts, :compensate),
      validate: Keyword.get(opts, :validate),
      retry_times: Keyword.get(opts, :retry_times, 0),
      backoff: Keyword.get(opts, :backoff, :exponential)
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
