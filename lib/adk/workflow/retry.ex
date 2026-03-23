defmodule ADK.Workflow.Retry do
  @moduledoc """
  Per-node retry logic for workflow steps.

  Wraps node execution with configurable retry count and backoff strategy.
  Retries are attempted when the node returns `{:error, _}` or raises an exception.

  ## Backoff Strategies

  - `:exponential` — `100ms * 2^attempt` (100, 200, 400, 800, ...)
  - `:linear` — `100ms * attempt` (100, 200, 300, ...)
  - integer — fixed delay in milliseconds (e.g., `500` → 500ms between each retry)

  ## Telemetry

  Emits `[:adk, :workflow, :node, :retry]` on each retry attempt with metadata:
  - `:workflow_id`, `:node_id`, `:attempt`, `:max_retries`, `:backoff_ms`, `:reason`
  """

  @base_delay_ms 100

  @doc """
  Execute `fun` with retry logic.

  `fun` is a zero-arity function that returns `{status, events, output}`.
  If `status` is not `:ok`, retries up to `retry_times` with the given `backoff`.
  """
  @spec with_retry(
          fun :: (-> {atom() | {:error, any()}, list(), any()}),
          retry_times :: non_neg_integer(),
          backoff :: :exponential | :linear | pos_integer(),
          meta :: map()
        ) :: {atom() | {:error, any()}, list(), any()}
  def with_retry(fun, retry_times, backoff, meta \\ %{})

  def with_retry(fun, 0, _backoff, _meta), do: fun.()

  def with_retry(fun, retry_times, backoff, meta) when retry_times > 0 do
    do_retry(fun, 0, retry_times, backoff, meta)
  end

  defp do_retry(fun, attempt, max_retries, backoff, meta) do
    {status, events, output} =
      try do
        fun.()
      rescue
        e ->
          reason = Exception.message(e)
          {{:error, {:exception, reason}}, [], nil}
      end

    if status == :ok or attempt >= max_retries do
      {status, events, output}
    else
      delay = backoff_delay(backoff, attempt)

      emit_retry_telemetry(meta, attempt + 1, max_retries, delay, status)

      if delay > 0, do: Process.sleep(delay)

      do_retry(fun, attempt + 1, max_retries, backoff, meta)
    end
  end

  @doc """
  Calculate backoff delay in milliseconds for a given attempt (0-indexed).
  """
  @spec backoff_delay(:exponential | :linear | pos_integer(), non_neg_integer()) ::
          non_neg_integer()
  def backoff_delay(:exponential, attempt) do
    @base_delay_ms * :math.pow(2, attempt) |> trunc()
  end

  def backoff_delay(:linear, attempt) do
    @base_delay_ms * (attempt + 1)
  end

  def backoff_delay(fixed_ms, _attempt) when is_integer(fixed_ms) and fixed_ms > 0 do
    fixed_ms
  end

  def backoff_delay(_other, _attempt), do: @base_delay_ms

  defp emit_retry_telemetry(meta, attempt, max_retries, delay, reason) do
    if function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute(
        [:adk, :workflow, :node, :retry],
        %{},
        Map.merge(meta, %{
          attempt: attempt,
          max_retries: max_retries,
          backoff_ms: delay,
          reason: reason
        })
      )
    end
  rescue
    _ -> :ok
  end
end
