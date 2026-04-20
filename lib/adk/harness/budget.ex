defmodule ADK.Harness.Budget do
  @moduledoc """
  Token/step/time budget tracking for `ADK.Harness`.

  Tracks consumption against configured limits and stops execution when
  any budget is exhausted. Supports shared budgets for multi-agent runs
  — the Harness owns the budget, all agents draw from it.

  Integrates with Gateway.Stats via `:telemetry.attach` on
  `[:adk, :llm, :request, :stop]` events to automatically count tokens.

  ADK Elixir extension — no Python ADK equivalent exists.
  """

  use Agent

  @type t :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          steps: non_neg_integer(),
          start_time: integer(),
          limits: map()
        }

  @doc """
  Start a new budget tracker as an Agent process.

  The `limits` map comes from `ADK.Harness.Config.budget`.

  ## Examples

      iex> {:ok, pid} = ADK.Harness.Budget.start_link(%{max_steps: 10})
      iex> is_pid(pid)
      true
  """
  @spec start_link(map()) :: {:ok, pid()}
  def start_link(limits) do
    Agent.start_link(fn ->
      %{
        input_tokens: 0,
        output_tokens: 0,
        steps: 0,
        start_time: System.monotonic_time(:millisecond),
        limits: limits
      }
    end)
  end

  @doc """
  Record token usage from an LLM call.

  ## Examples

      iex> {:ok, pid} = ADK.Harness.Budget.start_link(%{max_tokens: 1000})
      iex> ADK.Harness.Budget.record_tokens(pid, 50, 20)
      :ok
      iex> ADK.Harness.Budget.usage(pid).input_tokens
      50
  """
  @spec record_tokens(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  def record_tokens(pid, input_tokens, output_tokens) do
    Agent.update(pid, fn state ->
      %{
        state
        | input_tokens: state.input_tokens + input_tokens,
          output_tokens: state.output_tokens + output_tokens
      }
    end)
  end

  @doc """
  Increment the step counter by one.

  ## Examples

      iex> {:ok, pid} = ADK.Harness.Budget.start_link(%{max_steps: 10})
      iex> ADK.Harness.Budget.record_step(pid)
      :ok
      iex> ADK.Harness.Budget.usage(pid).steps
      1
  """
  @spec record_step(pid()) :: :ok
  def record_step(pid) do
    Agent.update(pid, fn state ->
      %{state | steps: state.steps + 1}
    end)
  end

  @doc """
  Check whether any budget limit has been exceeded.

  Returns `:ok` if within budget, or `{:exceeded, reason}` if any
  limit is hit.

  ## Examples

      iex> {:ok, pid} = ADK.Harness.Budget.start_link(%{max_steps: 1})
      iex> ADK.Harness.Budget.record_step(pid)
      iex> ADK.Harness.Budget.check(pid)
      {:exceeded, :max_steps}
  """
  @spec check(pid()) :: :ok | {:exceeded, atom()}
  def check(pid) do
    state = Agent.get(pid, & &1)
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.start_time
    total_tokens = state.input_tokens + state.output_tokens
    limits = state.limits

    cond do
      exceeded?(limits[:max_steps], state.steps) ->
        {:exceeded, :max_steps}

      exceeded?(limits[:max_tokens], total_tokens) ->
        {:exceeded, :max_tokens}

      exceeded?(limits[:max_input_tokens], state.input_tokens) ->
        {:exceeded, :max_input_tokens}

      exceeded?(limits[:max_output_tokens], state.output_tokens) ->
        {:exceeded, :max_output_tokens}

      exceeded?(limits[:max_duration_ms], elapsed) ->
        {:exceeded, :timeout}

      true ->
        :ok
    end
  end

  @doc """
  Return current usage as a map.

  ## Examples

      iex> {:ok, pid} = ADK.Harness.Budget.start_link(%{})
      iex> usage = ADK.Harness.Budget.usage(pid)
      iex> usage.steps
      0
  """
  @spec usage(pid()) :: t()
  def usage(pid) do
    Agent.get(pid, & &1)
  end

  @doc """
  Check if budget is above the warning threshold (80%).

  Returns `true` if any limit is above 80% consumed.
  """
  @spec warning?(pid()) :: boolean()
  def warning?(pid) do
    state = Agent.get(pid, & &1)
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.start_time
    total_tokens = state.input_tokens + state.output_tokens
    limits = state.limits

    above_threshold?(limits[:max_steps], state.steps) or
      above_threshold?(limits[:max_tokens], total_tokens) or
      above_threshold?(limits[:max_duration_ms], elapsed)
  end

  @doc """
  Attach a telemetry handler that automatically records token usage
  from LLM calls. Returns the handler ID for later detachment.

  ## Examples

      iex> id = ADK.Harness.Budget.attach_telemetry(self())
      iex> is_binary(id)
      true
      iex> :telemetry.detach(id)
      :ok
  """
  @spec attach_telemetry(pid()) :: String.t()
  def attach_telemetry(budget_pid) do
    handler_id = "adk-budget-#{inspect(budget_pid)}"

    :telemetry.attach(
      handler_id,
      [:adk, :llm, :request, :stop],
      &__MODULE__.telemetry_handler/4,
      budget_pid
    )

    handler_id
  end

  @doc false
  def telemetry_handler(_event, measurements, _metadata, budget_pid) do
    input = Map.get(measurements, :input_tokens, 0)
    output = Map.get(measurements, :output_tokens, 0)
    record_tokens(budget_pid, input, output)
  end

  defp exceeded?(nil, _current), do: false
  defp exceeded?(limit, current), do: current >= limit

  defp above_threshold?(nil, _current), do: false
  defp above_threshold?(limit, current), do: current / limit >= 0.8
end
