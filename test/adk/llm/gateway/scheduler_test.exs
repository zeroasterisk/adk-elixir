defmodule ADK.LLM.Gateway.SchedulerTest do
  use ExUnit.Case, async: true

  alias ADK.LLM.Gateway.Scheduler

  defp fake_dispatch(response \\ {:ok, %{text: "ok"}}) do
    fn _model, _request, _opts -> response end
  end

  defp start_scheduler(opts \\ []) do
    defaults = [
      dispatch_fn: fake_dispatch(),
      capacity_fn: fn -> 0.0 end,
      drain_interval_ms: 60_000,
      background_threshold: 0.8
    ]

    {:ok, pid} = Scheduler.start_link(Keyword.merge(defaults, opts))
    pid
  end

  describe "interactive priority" do
    test "dispatches immediately" do
      pid = start_scheduler()
      assert {:ok, %{text: "ok"}} = Scheduler.submit(pid, "model", %{}, priority: :interactive)
    end

    test "never queued even at full capacity" do
      pid = start_scheduler(capacity_fn: fn -> 1.0 end)
      assert {:ok, %{text: "ok"}} = Scheduler.submit(pid, "model", %{}, priority: :interactive)
      assert %{interactive: 0} = Scheduler.queue_depth(pid)
    end

    test "returns errors from dispatch" do
      pid = start_scheduler(dispatch_fn: fake_dispatch({:error, :rate_limited}))
      assert {:error, :rate_limited} = Scheduler.submit(pid, "model", %{}, priority: :interactive)
    end
  end

  describe "background priority" do
    test "dispatches immediately when under threshold" do
      pid = start_scheduler(capacity_fn: fn -> 0.5 end)
      assert {:ok, %{text: "ok"}} = Scheduler.submit(pid, "model", %{}, priority: :background)
      assert %{background: 0} = Scheduler.queue_depth(pid)
    end

    test "queues when at or above threshold" do
      pid = start_scheduler(capacity_fn: fn -> 0.9 end)

      # Submit in a task since it will block
      task =
        Task.async(fn ->
          Scheduler.submit(pid, "model", %{}, priority: :background, timeout: 5_000)
        end)

      :timer.sleep(20)
      assert %{background: 1} = Scheduler.queue_depth(pid)

      # Flush to unblock
      Scheduler.flush(pid)
      assert {:ok, %{text: "ok"}} = Task.await(task, 5_000)
    end
  end

  describe "batch priority" do
    test "always queues" do
      pid = start_scheduler(capacity_fn: fn -> 0.0 end)

      task =
        Task.async(fn ->
          Scheduler.submit(pid, "model", %{}, priority: :batch, timeout: 5_000)
        end)

      :timer.sleep(20)
      assert %{batch: 1} = Scheduler.queue_depth(pid)

      Scheduler.flush(pid)
      assert {:ok, %{text: "ok"}} = Task.await(task, 5_000)
    end

    test "multiple batch requests queue in order" do
      counter = :counters.new(1, [:atomics])

      dispatch_fn = fn _model, _request, _opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        {:ok, %{n: n}}
      end

      pid = start_scheduler(dispatch_fn: dispatch_fn)

      tasks =
        for _i <- 1..3 do
          Task.async(fn ->
            Scheduler.submit(pid, "model", %{}, priority: :batch, timeout: 5_000)
          end)
        end

      :timer.sleep(30)
      assert %{batch: 3} = Scheduler.queue_depth(pid)

      Scheduler.flush(pid)

      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end
  end

  describe "queue_depth/1" do
    test "returns zeroes initially" do
      pid = start_scheduler()
      assert %{interactive: 0, background: 0, batch: 0} = Scheduler.queue_depth(pid)
    end
  end

  describe "flush/1" do
    test "drains all queues" do
      pid = start_scheduler(capacity_fn: fn -> 0.95 end)

      tasks =
        for priority <- [:background, :batch, :batch] do
          Task.async(fn ->
            Scheduler.submit(pid, "model", %{}, priority: priority, timeout: 5_000)
          end)
        end

      :timer.sleep(30)
      assert %{background: 1, batch: 2} = Scheduler.queue_depth(pid)

      Scheduler.flush(pid)

      for task <- tasks do
        assert {:ok, _} = Task.await(task, 5_000)
      end

      assert %{background: 0, batch: 0} = Scheduler.queue_depth(pid)
    end
  end

  describe "drain timer" do
    test "automatically drains background queue when capacity available" do
      # Use mutable capacity that starts high then drops
      capacity = :atomics.new(1, [])
      :atomics.put(capacity, 1, 90)

      capacity_fn = fn -> :atomics.get(capacity, 1) / 100.0 end

      pid =
        start_scheduler(
          capacity_fn: capacity_fn,
          drain_interval_ms: 50
        )

      task =
        Task.async(fn ->
          Scheduler.submit(pid, "model", %{}, priority: :background, timeout: 5_000)
        end)

      :timer.sleep(20)
      assert %{background: 1} = Scheduler.queue_depth(pid)

      # Lower capacity so drain timer will dispatch
      :atomics.put(capacity, 1, 30)

      # Wait for drain timer
      :timer.sleep(100)

      assert {:ok, %{text: "ok"}} = Task.await(task, 5_000)
      assert %{background: 0} = Scheduler.queue_depth(pid)
    end
  end

  describe "default priority" do
    test "uses configured default" do
      pid =
        start_scheduler(
          default_priority: :background,
          capacity_fn: fn -> 0.95 end
        )

      task =
        Task.async(fn ->
          Scheduler.submit(pid, "model", %{}, timeout: 5_000)
        end)

      :timer.sleep(20)
      assert %{background: 1} = Scheduler.queue_depth(pid)

      Scheduler.flush(pid)
      Task.await(task, 5_000)
    end
  end
end
