defmodule ADK.LLM.Retry do
  @moduledoc """
  Retry wrapper for LLM calls with exponential backoff and jitter.

  Retries on transient errors (HTTP 429, 500, 502, 503, 504, connection errors).
  Does NOT retry on client errors (400, 401, 403, 404).

  ## Options

    * `:max_retries` - Maximum number of retry attempts (default: 3)
    * `:base_delay_ms` - Base delay in milliseconds (default: 1000)
    * `:max_delay_ms` - Maximum delay in milliseconds (default: 30_000)

  ## Examples

      ADK.LLM.Retry.with_retry(fn -> ADK.LLM.Gemini.generate(model, request) end)

      ADK.LLM.Retry.with_retry(
        fn -> ADK.LLM.Gemini.generate(model, request) end,
        max_retries: 5, base_delay_ms: 500
      )
  """

  @default_max_retries 3
  @default_base_delay_ms 1_000
  @default_max_delay_ms 30_000

  @doc """
  Execute `fun` with retry logic. Returns the first success or the last error.
  """
  @spec with_retry((() -> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    max_delay_ms = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)

    do_retry(fun, 0, max_retries, base_delay_ms, max_delay_ms, sleep_fn)
  end

  defp do_retry(fun, attempt, max_retries, base_delay_ms, max_delay_ms, sleep_fn) do
    case fun.() do
      {:ok, _} = success ->
        success

      {:error, reason} = error ->
        if attempt < max_retries and transient?(reason) do
          delay = compute_delay(attempt, base_delay_ms, max_delay_ms)
          sleep_fn.(delay)
          do_retry(fun, attempt + 1, max_retries, base_delay_ms, max_delay_ms, sleep_fn)
        else
          error
        end
    end
  end

  @doc """
  Compute backoff delay with jitter for the given attempt.
  """
  @spec compute_delay(non_neg_integer(), pos_integer(), pos_integer()) :: non_neg_integer()
  def compute_delay(attempt, base_delay_ms, max_delay_ms) do
    # Exponential backoff: base * 2^attempt
    exp_delay = base_delay_ms * Integer.pow(2, attempt)
    capped = min(exp_delay, max_delay_ms)
    # Full jitter: random value in [0, capped]
    :rand.uniform(capped + 1) - 1
  end

  @doc """
  Returns true if the error is transient and should be retried.
  """
  @spec transient?(term()) :: boolean()
  def transient?(:rate_limited), do: true
  def transient?({:api_error, status, _}) when status in [500, 502, 503, 504], do: true
  def transient?({:request_failed, _}), do: true
  def transient?(:timeout), do: true
  def transient?(:econnrefused), do: true
  def transient?(:closed), do: true
  def transient?(_), do: false
end
