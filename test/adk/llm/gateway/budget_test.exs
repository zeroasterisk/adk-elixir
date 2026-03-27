defmodule ADK.LLM.Gateway.BudgetTest do
  use ExUnit.Case, async: true

  alias ADK.LLM.Gateway.Budget

  defp start_budget(configs) do
    {:ok, pid} = Budget.start_link(budgets: configs)
    pid
  end

  defp default_budgets do
    [
      %{name: :default, max_total_tokens: 1000, period: :session},
      %{name: :daily, max_total_tokens: 5000, period: :daily},
      %{name: :lifetime, max_total_tokens: 100_000, period: :lifetime}
    ]
  end

  describe "check/3" do
    test "allows requests within budget" do
      pid = start_budget(default_budgets())
      assert :ok = Budget.check(pid, :default, 500)
    end

    test "allows requests exactly at limit" do
      pid = start_budget(default_budgets())
      assert :ok = Budget.check(pid, :default, 1000)
    end

    test "rejects requests over budget" do
      pid = start_budget(default_budgets())
      assert :ok = Budget.record(pid, :default, 900)
      assert {:error, :budget_exceeded} = Budget.check(pid, :default, 200)
    end

    test "returns error for unknown budget" do
      pid = start_budget(default_budgets())
      assert {:error, :unknown_budget} = Budget.check(pid, :nonexistent, 100)
    end
  end

  describe "record/3" do
    test "tracks cumulative usage" do
      pid = start_budget(default_budgets())
      assert :ok = Budget.record(pid, :default, 300)
      assert :ok = Budget.record(pid, :default, 400)
      assert {:ok, %{used: 700, remaining: 300}} = Budget.status(pid, :default)
    end

    test "allows recording beyond max (soft limit)" do
      pid = start_budget(default_budgets())
      assert :ok = Budget.record(pid, :default, 1500)
      assert {:ok, %{used: 1500, remaining: 0}} = Budget.status(pid, :default)
    end

    test "returns error for unknown budget" do
      pid = start_budget(default_budgets())
      assert {:error, :unknown_budget} = Budget.record(pid, :nonexistent, 100)
    end
  end

  describe "status/2" do
    test "returns full status" do
      pid = start_budget(default_budgets())
      assert :ok = Budget.record(pid, :default, 250)

      assert {:ok, status} = Budget.status(pid, :default)
      assert status.used == 250
      assert status.remaining == 750
      assert status.max == 1000
      assert status.period == :session
    end

    test "returns error for unknown budget" do
      pid = start_budget(default_budgets())
      assert {:error, :unknown_budget} = Budget.status(pid, :nonexistent)
    end
  end

  describe "reset/2" do
    test "resets a single budget" do
      pid = start_budget(default_budgets())
      Budget.record(pid, :default, 500)
      Budget.record(pid, :daily, 2000)

      assert :ok = Budget.reset(pid, :default)
      assert {:ok, %{used: 0}} = Budget.status(pid, :default)
      assert {:ok, %{used: 2000}} = Budget.status(pid, :daily)
    end

    test "returns error for unknown budget" do
      pid = start_budget(default_budgets())
      assert {:error, :unknown_budget} = Budget.reset(pid, :nonexistent)
    end
  end

  describe "reset_all/1" do
    test "resets all budgets" do
      pid = start_budget(default_budgets())
      Budget.record(pid, :default, 500)
      Budget.record(pid, :daily, 2000)
      Budget.record(pid, :lifetime, 50_000)

      assert :ok = Budget.reset_all(pid)
      assert {:ok, %{used: 0}} = Budget.status(pid, :default)
      assert {:ok, %{used: 0}} = Budget.status(pid, :daily)
      assert {:ok, %{used: 0}} = Budget.status(pid, :lifetime)
    end
  end

  describe "daily reset" do
    test "daily_reset message resets only daily budgets" do
      pid = start_budget(default_budgets())
      Budget.record(pid, :default, 500)
      Budget.record(pid, :daily, 3000)
      Budget.record(pid, :lifetime, 50_000)

      # Simulate the daily reset timer firing
      send(pid, :daily_reset)
      # Allow GenServer to process
      :timer.sleep(10)

      assert {:ok, %{used: 500}} = Budget.status(pid, :default)
      assert {:ok, %{used: 0}} = Budget.status(pid, :daily)
      assert {:ok, %{used: 50_000}} = Budget.status(pid, :lifetime)
    end
  end

  describe "empty budgets" do
    test "starts with no budgets" do
      {:ok, pid} = Budget.start_link(budgets: [])
      assert {:error, :unknown_budget} = Budget.check(pid, :anything, 100)
    end
  end
end
