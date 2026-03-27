defmodule ADK.Harness.BudgetTest do
  use ExUnit.Case, async: true

  alias ADK.Harness.Budget

  describe "start_link/1" do
    test "starts with zero usage" do
      {:ok, pid} = Budget.start_link(%{})
      usage = Budget.usage(pid)
      assert usage.steps == 0
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
    end
  end

  describe "record_tokens/3" do
    test "accumulates token counts" do
      {:ok, pid} = Budget.start_link(%{})
      Budget.record_tokens(pid, 100, 50)
      Budget.record_tokens(pid, 200, 75)
      usage = Budget.usage(pid)
      assert usage.input_tokens == 300
      assert usage.output_tokens == 125
    end
  end

  describe "record_step/1" do
    test "increments step count" do
      {:ok, pid} = Budget.start_link(%{})
      Budget.record_step(pid)
      Budget.record_step(pid)
      assert Budget.usage(pid).steps == 2
    end
  end

  describe "check/1" do
    test "returns :ok when within budget" do
      {:ok, pid} = Budget.start_link(%{max_steps: 10, max_tokens: 1000})
      Budget.record_step(pid)
      assert Budget.check(pid) == :ok
    end

    test "returns exceeded when max_steps hit" do
      {:ok, pid} = Budget.start_link(%{max_steps: 2})
      Budget.record_step(pid)
      Budget.record_step(pid)
      assert Budget.check(pid) == {:exceeded, :max_steps}
    end

    test "returns exceeded when max_tokens hit" do
      {:ok, pid} = Budget.start_link(%{max_tokens: 100})
      Budget.record_tokens(pid, 60, 50)
      assert Budget.check(pid) == {:exceeded, :max_tokens}
    end

    test "returns exceeded when max_input_tokens hit" do
      {:ok, pid} = Budget.start_link(%{max_input_tokens: 50})
      Budget.record_tokens(pid, 50, 0)
      assert Budget.check(pid) == {:exceeded, :max_input_tokens}
    end

    test "returns exceeded when max_output_tokens hit" do
      {:ok, pid} = Budget.start_link(%{max_output_tokens: 30})
      Budget.record_tokens(pid, 0, 30)
      assert Budget.check(pid) == {:exceeded, :max_output_tokens}
    end

    test "returns exceeded for timeout" do
      {:ok, pid} = Budget.start_link(%{max_duration_ms: 1})
      Process.sleep(5)
      assert Budget.check(pid) == {:exceeded, :timeout}
    end

    test "returns :ok with nil limits" do
      {:ok, pid} = Budget.start_link(%{})
      Budget.record_step(pid)
      Budget.record_tokens(pid, 999_999, 999_999)
      assert Budget.check(pid) == :ok
    end
  end

  describe "warning?/1" do
    test "returns false when well within budget" do
      {:ok, pid} = Budget.start_link(%{max_steps: 10})
      Budget.record_step(pid)
      refute Budget.warning?(pid)
    end

    test "returns true when above 80% of steps" do
      {:ok, pid} = Budget.start_link(%{max_steps: 10})
      for _ <- 1..8, do: Budget.record_step(pid)
      assert Budget.warning?(pid)
    end

    test "returns true when above 80% of tokens" do
      {:ok, pid} = Budget.start_link(%{max_tokens: 100})
      Budget.record_tokens(pid, 50, 35)
      assert Budget.warning?(pid)
    end
  end

  describe "attach_telemetry/1" do
    test "returns handler id and detaches cleanly" do
      {:ok, pid} = Budget.start_link(%{})
      id = Budget.attach_telemetry(pid)
      assert is_binary(id)
      assert :ok == :telemetry.detach(id)
    end
  end
end
