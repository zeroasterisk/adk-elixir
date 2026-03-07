defmodule ADK.LLM.RetryTest do
  use ExUnit.Case, async: true

  alias ADK.LLM.Retry

  defp no_sleep(_ms), do: :ok

  describe "with_retry/2" do
    test "returns success on first try" do
      result = Retry.with_retry(fn -> {:ok, :done} end, sleep_fn: &no_sleep/1)
      assert result == {:ok, :done}
    end

    test "retries on transient error and succeeds" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) < 3 do
          {:error, :rate_limited}
        else
          {:ok, :recovered}
        end
      end

      assert {:ok, :recovered} = Retry.with_retry(fun, sleep_fn: &no_sleep/1)
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry on client errors" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        {:error, :unauthorized}
      end

      assert {:error, :unauthorized} = Retry.with_retry(fun, sleep_fn: &no_sleep/1)
      assert :counters.get(counter, 1) == 1
    end

    test "does not retry on api_error 400" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        {:error, {:api_error, 400, "bad request"}}
      end

      assert {:error, {:api_error, 400, _}} = Retry.with_retry(fun, sleep_fn: &no_sleep/1)
      assert :counters.get(counter, 1) == 1
    end

    test "retries on api_error 500" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        {:error, {:api_error, 500, "internal"}}
      end

      assert {:error, {:api_error, 500, _}} =
               Retry.with_retry(fun, max_retries: 2, sleep_fn: &no_sleep/1)

      # 1 initial + 2 retries = 3
      assert :counters.get(counter, 1) == 3
    end

    test "retries on connection errors" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        {:error, {:request_failed, :econnrefused}}
      end

      assert {:error, _} = Retry.with_retry(fun, max_retries: 1, sleep_fn: &no_sleep/1)
      assert :counters.get(counter, 1) == 2
    end

    test "respects max_retries" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        {:error, :rate_limited}
      end

      assert {:error, :rate_limited} =
               Retry.with_retry(fun, max_retries: 5, sleep_fn: &no_sleep/1)

      assert :counters.get(counter, 1) == 6
    end
  end

  describe "transient?/1" do
    test "rate_limited is transient" do
      assert Retry.transient?(:rate_limited)
    end

    test "server errors are transient" do
      for status <- [500, 502, 503, 504] do
        assert Retry.transient?({:api_error, status, "err"})
      end
    end

    test "client errors are not transient" do
      refute Retry.transient?(:unauthorized)
      refute Retry.transient?({:api_error, 400, "bad"})
      refute Retry.transient?({:api_error, 401, "unauth"})
      refute Retry.transient?({:api_error, 403, "forbidden"})
      refute Retry.transient?({:api_error, 404, "not found"})
    end

    test "request_failed is transient" do
      assert Retry.transient?({:request_failed, :econnrefused})
    end
  end

  describe "compute_delay/3" do
    test "delay is within expected bounds" do
      for attempt <- 0..5 do
        delay = Retry.compute_delay(attempt, 1000, 30_000)
        max_expected = min(1000 * Integer.pow(2, attempt), 30_000)
        assert delay >= 0
        assert delay <= max_expected
      end
    end

    test "delay is capped at max" do
      delay = Retry.compute_delay(20, 1000, 5000)
      assert delay <= 5000
    end
  end
end
