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

  `fun` should return `{:ok, result}` or `{:error, reason}`.

  ## Options

    * `:retry_after_ms` - If set, overrides the computed backoff for the first
      retry attempt (useful when the server sends a `retry-after` header).
    * `:max_retries`, `:base_delay_ms`, `:max_delay_ms` - see module docs.
    * `:sleep_fn` - override for testing (default: `&Process.sleep/1`).
  """
  @spec with_retry((-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    max_delay_ms = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    retry_after_ms = Keyword.get(opts, :retry_after_ms)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)

    do_retry(fun, 0, %{
      max_retries: max_retries,
      base_delay_ms: base_delay_ms,
      max_delay_ms: max_delay_ms,
      retry_after_ms: retry_after_ms,
      sleep_fn: sleep_fn
    })
  end

  defp do_retry(fun, attempt, opts) do
    case fun.() do
      {:ok, _} = success ->
        success

      {:retry_after, ms, reason} ->
        # The function signals a server-suggested retry delay
        error = {:error, reason}

        if attempt < opts.max_retries and transient?(reason) do
          delay =
            if is_integer(ms) and ms > 0,
              do: min(ms, opts.max_delay_ms),
              else: compute_delay(attempt, opts.base_delay_ms, opts.max_delay_ms)

          opts.sleep_fn.(delay)
          do_retry(fun, attempt + 1, %{opts | retry_after_ms: nil})
        else
          error
        end

      {:error, reason} = error ->
        if attempt < opts.max_retries and transient?(reason) do
          delay =
            if attempt == 0 and is_integer(opts.retry_after_ms) and opts.retry_after_ms > 0 do
              min(opts.retry_after_ms, opts.max_delay_ms)
            else
              compute_delay(attempt, opts.base_delay_ms, opts.max_delay_ms)
            end

          opts.sleep_fn.(delay)
          do_retry(fun, attempt + 1, %{opts | retry_after_ms: nil})
        else
          error
        end
    end
  end

  @doc """
  Extract a retry-after delay (in milliseconds) from a `Req.Response`.

  Checks for Anthropic's `retry-after-ms` header first, then the standard
  `retry-after` header (interpreted as seconds). Returns `nil` if neither
  is present or parseable.
  """
  @spec extract_retry_after(%{headers: term()}) :: non_neg_integer() | nil
  def extract_retry_after(%{headers: headers}) when is_map(headers) do
    with nil <- parse_header_ms(Map.get(headers, "retry-after-ms", [])),
         nil <- parse_header_secs(Map.get(headers, "retry-after", [])) do
      nil
    end
  end

  def extract_retry_after(%{headers: headers}) when is_list(headers) do
    # Legacy tuple-list headers
    ms_val = :proplists.get_value("retry-after-ms", headers)
    secs_val = :proplists.get_value("retry-after", headers)

    with nil <- safe_parse_int(ms_val),
         nil <- safe_parse_int_as_ms(secs_val) do
      nil
    end
  end

  def extract_retry_after(_), do: nil

  defp parse_header_ms([val | _]) when is_binary(val), do: safe_parse_int(val)
  defp parse_header_ms(_), do: nil

  defp parse_header_secs([val | _]) when is_binary(val) do
    case safe_parse_int(val) do
      nil -> nil
      secs -> secs * 1000
    end
  end

  defp parse_header_secs(_), do: nil

  defp safe_parse_int_as_ms(val) do
    case safe_parse_int(val) do
      nil -> nil
      secs -> secs * 1000
    end
  end

  defp safe_parse_int(nil), do: nil

  defp safe_parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp safe_parse_int(_), do: nil

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
  def transient?(:overloaded), do: true
  def transient?({:api_error, status, _}) when status in [500, 502, 503, 504, 529], do: true
  def transient?({:request_failed, _}), do: true
  def transient?(:timeout), do: true
  def transient?(:econnrefused), do: true
  def transient?(:closed), do: true
  def transient?(_), do: false
end
