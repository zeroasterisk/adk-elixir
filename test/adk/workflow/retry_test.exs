defmodule ADK.Workflow.RetryTest do
  use ExUnit.Case, async: true

  alias ADK.Workflow.{Retry, Step, Graph, Executor}

  # ── Unit tests for Retry module ──

  describe "backoff_delay/2" do
    test "exponential backoff" do
      assert Retry.backoff_delay(:exponential, 0) == 100
      assert Retry.backoff_delay(:exponential, 1) == 200
      assert Retry.backoff_delay(:exponential, 2) == 400
      assert Retry.backoff_delay(:exponential, 3) == 800
    end

    test "linear backoff" do
      assert Retry.backoff_delay(:linear, 0) == 100
      assert Retry.backoff_delay(:linear, 1) == 200
      assert Retry.backoff_delay(:linear, 2) == 300
      assert Retry.backoff_delay(:linear, 3) == 400
    end

    test "fixed delay backoff" do
      assert Retry.backoff_delay(500, 0) == 500
      assert Retry.backoff_delay(500, 1) == 500
      assert Retry.backoff_delay(500, 5) == 500
    end
  end

  describe "with_retry/4" do
    test "no retries when retry_times is 0" do
      counter = :counters.new(1, [])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, [], nil}
          end,
          0,
          :exponential
        )

      assert result == {:ok, [], nil}
      assert :counters.get(counter, 1) == 1
    end

    test "no retry when first attempt succeeds" do
      counter = :counters.new(1, [])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, ["event"], "output"}
          end,
          3,
          :exponential
        )

      assert result == {:ok, ["event"], "output"}
      assert :counters.get(counter, 1) == 1
    end

    test "retries on error and eventually succeeds" do
      counter = :counters.new(1, [])

      result =
        Retry.with_retry(
          fn ->
            count = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)

            if count < 2 do
              {{:error, :transient}, [], nil}
            else
              {:ok, ["success"], "done"}
            end
          end,
          3,
          # 1ms fixed delay for fast tests
          1
        )

      assert result == {:ok, ["success"], "done"}
      # Should have been called 3 times (initial + 2 retries)
      assert :counters.get(counter, 1) == 3
    end

    test "gives up after max retries exceeded" do
      counter = :counters.new(1, [])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {{:error, :always_fails}, [], nil}
          end,
          2,
          # 1ms fixed delay
          1
        )

      assert {{:error, :always_fails}, [], nil} = result
      # initial + 2 retries = 3 total
      assert :counters.get(counter, 1) == 3
    end

    test "retries on raised exception" do
      counter = :counters.new(1, [])

      result =
        Retry.with_retry(
          fn ->
            count = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)

            if count < 1 do
              raise "transient error"
            else
              {:ok, [], "recovered"}
            end
          end,
          2,
          1
        )

      assert {:ok, [], "recovered"} = result
      assert :counters.get(counter, 1) == 2
    end
  end

  # ── Integration tests: Step + Executor with retry ──

  describe "Step with retry in executor" do
    setup do
      # Ensure ETS checkpoint store is available
      if function_exported?(ADK.Workflow.Checkpoint.EtsStore, :init, 0) do
        ADK.Workflow.Checkpoint.EtsStore.init()
      end

      ctx = %ADK.Context{
        invocation_id: "test-retry-#{System.unique_integer([:positive])}"
      }

      {:ok, ctx: ctx}
    end

    test "step succeeds on first try — no retries", %{ctx: ctx} do
      step = %Step{
        name: :fast,
        run: fn _ctx -> "instant success" end,
        retry_times: 3,
        backoff: :exponential
      }

      graph = Graph.build([{:START, :fast}, {:fast, :END}], %{fast: step})
      events = Executor.run(graph, ctx)

      assert length(events) >= 1
      text = events |> Enum.map(&ADK.Event.text/1) |> Enum.reject(&is_nil/1) |> Enum.join()
      assert text =~ "instant success"
    end

    test "step retries on transient failure then succeeds", %{ctx: ctx} do
      counter = :counters.new(1, [])

      step = %Step{
        name: :flaky,
        run: fn _ctx ->
          count = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if count < 2 do
            {:error, :transient}
          else
            "recovered!"
          end
        end,
        retry_times: 3,
        # 1ms for fast tests
        backoff: 1
      }

      graph = Graph.build([{:START, :flaky}, {:flaky, :END}], %{flaky: step})
      events = Executor.run(graph, ctx)

      # Should have retried and succeeded
      assert :counters.get(counter, 1) == 3
      texts = events |> Enum.map(&ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert Enum.any?(texts, &(&1 =~ "recovered!"))
    end

    test "step exhausts retries and workflow fails", %{ctx: ctx} do
      counter = :counters.new(1, [])

      step = %Step{
        name: :doomed,
        run: fn _ctx ->
          :counters.add(counter, 1, 1)
          {:error, :permanent}
        end,
        retry_times: 2,
        backoff: 1
      }

      graph = Graph.build([{:START, :doomed}, {:doomed, :END}], %{doomed: step})
      events = Executor.run(graph, ctx)

      # initial + 2 retries = 3 attempts
      assert :counters.get(counter, 1) == 3

      # Should contain error event
      texts = events |> Enum.map(&ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert Enum.any?(texts, &(&1 =~ "failed" or &1 =~ "error" or &1 =~ "permanent"))
    end

    test "step with exponential backoff takes measurably longer", %{ctx: ctx} do
      counter = :counters.new(1, [])

      step = %Step{
        name: :slow_retry,
        run: fn _ctx ->
          count = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if count < 2 do
            {:error, :needs_time}
          else
            "ok"
          end
        end,
        retry_times: 3,
        # 100ms, 200ms
        backoff: :exponential
      }

      graph = Graph.build([{:START, :slow_retry}, {:slow_retry, :END}], %{slow_retry: step})

      start = System.monotonic_time(:millisecond)
      _events = Executor.run(graph, ctx)
      elapsed = System.monotonic_time(:millisecond) - start

      # Exponential: attempt 0 fail → sleep 100ms, attempt 1 fail → sleep 200ms, attempt 2 ok
      # Total sleep ~300ms
      assert elapsed >= 250, "Expected at least 250ms of backoff, got #{elapsed}ms"
    end

    test "step with linear backoff", %{ctx: ctx} do
      counter = :counters.new(1, [])

      step = %Step{
        name: :linear_retry,
        run: fn _ctx ->
          count = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if count < 2 do
            {:error, :retry_me}
          else
            "linear ok"
          end
        end,
        retry_times: 3,
        # 100ms, 200ms
        backoff: :linear
      }

      graph =
        Graph.build([{:START, :linear_retry}, {:linear_retry, :END}], %{linear_retry: step})

      start = System.monotonic_time(:millisecond)
      _events = Executor.run(graph, ctx)
      elapsed = System.monotonic_time(:millisecond) - start

      # Linear: attempt 0 fail → sleep 100ms, attempt 1 fail → sleep 200ms, attempt 2 ok
      # Total ~300ms
      assert elapsed >= 250, "Expected at least 250ms of linear backoff, got #{elapsed}ms"
      assert :counters.get(counter, 1) == 3
    end

    test "step with fixed delay backoff", %{ctx: ctx} do
      counter = :counters.new(1, [])

      step = %Step{
        name: :fixed_retry,
        run: fn _ctx ->
          count = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if count < 1 do
            {:error, :once}
          else
            "fixed ok"
          end
        end,
        retry_times: 1,
        # 50ms fixed
        backoff: 50
      }

      graph =
        Graph.build([{:START, :fixed_retry}, {:fixed_retry, :END}], %{fixed_retry: step})

      start = System.monotonic_time(:millisecond)
      events = Executor.run(graph, ctx)
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed >= 40, "Expected at least 40ms of fixed backoff, got #{elapsed}ms"
      assert :counters.get(counter, 1) == 2
      texts = events |> Enum.map(&ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert Enum.any?(texts, &(&1 =~ "fixed ok"))
    end

    test "new_with_opts creates step with retry config" do
      step = Step.new_with_opts(:my_step, fn _ -> "ok" end, retry_times: 5, backoff: :linear)

      assert step.retry_times == 5
      assert step.backoff == :linear
      assert step.name == :my_step
      assert is_function(step.run)
    end

    test "new_with_opts defaults" do
      step = Step.new_with_opts(:basic, fn _ -> "ok" end)

      assert step.retry_times == 0
      assert step.backoff == :exponential
      assert step.compensate == nil
      assert step.validate == nil
    end

    test "step with retry + compensation rolls back on exhausted retries", %{ctx: ctx} do
      counter = :counters.new(1, [])
      comp_counter = :counters.new(1, [])

      step1 = %Step{
        name: :good,
        run: fn _ctx -> "step1 done" end,
        compensate: fn _ctx ->
          :counters.add(comp_counter, 1, 1)
          "compensated"
        end
      }

      step2 = %Step{
        name: :bad,
        run: fn _ctx ->
          :counters.add(counter, 1, 1)
          {:error, :fatal}
        end,
        retry_times: 2,
        backoff: 1
      }

      graph =
        Graph.build(
          [{:START, :good}, {:good, :bad}, {:bad, :END}],
          %{good: step1, bad: step2}
        )

      _events = Executor.run(graph, ctx)

      # step2 should have retried 2 times + initial = 3
      assert :counters.get(counter, 1) == 3
      # step1's compensation should have been called
      assert :counters.get(comp_counter, 1) == 1
    end
  end
end
