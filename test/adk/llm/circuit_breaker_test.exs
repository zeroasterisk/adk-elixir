defmodule ADK.LLM.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias ADK.LLM.CircuitBreaker

  setup do
    name = :"cb_test_#{:erlang.unique_integer([:positive])}"

    {:ok, pid} =
      CircuitBreaker.start_link(name: name, failure_threshold: 3, reset_timeout_ms: 100)

    %{cb: name, pid: pid}
  end

  describe "closed state" do
    test "passes calls through when closed", %{cb: cb} do
      assert :closed == CircuitBreaker.get_state(cb)
      assert {:ok, :result} = CircuitBreaker.call(cb, fn -> {:ok, :result} end)
    end

    test "stays closed on success", %{cb: cb} do
      CircuitBreaker.call(cb, fn -> {:ok, :ok} end)
      assert :closed == CircuitBreaker.get_state(cb)
    end
  end

  describe "opening the circuit" do
    test "opens after failure_threshold failures", %{cb: cb} do
      for _ <- 1..3 do
        CircuitBreaker.call(cb, fn -> {:error, :boom} end)
      end

      # Give casts time to process
      Process.sleep(10)
      assert :open == CircuitBreaker.get_state(cb)
    end

    test "rejects calls when open", %{cb: cb} do
      for _ <- 1..3 do
        CircuitBreaker.call(cb, fn -> {:error, :boom} end)
      end

      Process.sleep(10)

      assert {:error, :circuit_open} = CircuitBreaker.call(cb, fn -> {:ok, :nope} end)
    end
  end

  describe "half-open state" do
    test "transitions to half-open after timeout", %{cb: cb} do
      for _ <- 1..3 do
        CircuitBreaker.call(cb, fn -> {:error, :boom} end)
      end

      Process.sleep(10)
      assert :open == CircuitBreaker.get_state(cb)

      # Wait for reset timeout
      Process.sleep(110)
      assert :half_open == CircuitBreaker.get_state(cb)
    end

    test "closes on success in half-open", %{cb: cb} do
      for _ <- 1..3 do
        CircuitBreaker.call(cb, fn -> {:error, :boom} end)
      end

      Process.sleep(110)

      assert {:ok, :recovered} = CircuitBreaker.call(cb, fn -> {:ok, :recovered} end)
      Process.sleep(10)
      assert :closed == CircuitBreaker.get_state(cb)
    end

    test "reopens on failure in half-open", %{cb: cb} do
      for _ <- 1..3 do
        CircuitBreaker.call(cb, fn -> {:error, :boom} end)
      end

      Process.sleep(110)

      assert {:error, :still_bad} = CircuitBreaker.call(cb, fn -> {:error, :still_bad} end)
      Process.sleep(10)
      assert :open == CircuitBreaker.get_state(cb)
    end
  end

  describe "reset/1" do
    test "resets to closed state", %{cb: cb} do
      for _ <- 1..3 do
        CircuitBreaker.call(cb, fn -> {:error, :boom} end)
      end

      Process.sleep(10)
      assert :open == CircuitBreaker.get_state(cb)

      CircuitBreaker.reset(cb)
      assert :closed == CircuitBreaker.get_state(cb)
    end
  end

  describe "success resets failure count" do
    test "a success resets the count so it takes threshold again to open", %{cb: cb} do
      CircuitBreaker.call(cb, fn -> {:error, :e1} end)
      CircuitBreaker.call(cb, fn -> {:error, :e2} end)
      CircuitBreaker.call(cb, fn -> {:ok, :reset} end)
      Process.sleep(10)

      # Should still be closed, count was reset
      assert :closed == CircuitBreaker.get_state(cb)

      # Need 3 more failures to open
      CircuitBreaker.call(cb, fn -> {:error, :e1} end)
      CircuitBreaker.call(cb, fn -> {:error, :e2} end)
      Process.sleep(10)
      assert :closed == CircuitBreaker.get_state(cb)

      CircuitBreaker.call(cb, fn -> {:error, :e3} end)
      Process.sleep(10)
      assert :open == CircuitBreaker.get_state(cb)
    end
  end
end
