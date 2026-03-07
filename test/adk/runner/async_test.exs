defmodule ADK.Runner.AsyncTest do
  use ExUnit.Case, async: true

  setup do
    agent =
      ADK.Agent.LlmAgent.new(
        name: "test_agent",
        model: "test",
        instruction: "Say hello"
      )

    runner = %ADK.Runner{app_name: "async_test", agent: agent}
    {:ok, runner: runner}
  end

  test "run/5 sends events as messages", %{runner: runner} do
    {:ok, _pid} = ADK.Runner.Async.run(runner, "user1", "sess1", "hi")

    assert_receive {:adk_event, %ADK.Event{} = event}, 5000
    assert event.author != "user"
    assert_receive {:adk_done, events}, 5000
    assert is_list(events)
    assert length(events) > 0
  end

  test "run/5 sends to custom reply_to", %{runner: runner} do
    test_pid = self()

    spawn(fn ->
      {:ok, _pid} =
        ADK.Runner.Async.run(runner, "user1", "sess2", "hi", reply_to: test_pid)
    end)

    assert_receive {:adk_event, %ADK.Event{}}, 5000
    assert_receive {:adk_done, _events}, 5000
  end

  test "run_task/5 returns a Task", %{runner: runner} do
    task = ADK.Runner.Async.run_task(runner, "user1", "sess3", "hi")
    assert %Task{} = task

    assert_receive {:adk_event, %ADK.Event{}}, 5000
    events = Task.await(task, 5000)
    assert is_list(events)
  end
end
