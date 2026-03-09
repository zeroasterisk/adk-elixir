defmodule ADK.Plugin.ReflectRetryIntegrationTest do
  use ExUnit.Case, async: false

  alias ADK.Plugin.ReflectRetry

  setup do
    # Start required infrastructure
    unless Process.whereis(ADK.SessionSupervisor) do
      start_supervised!({DynamicSupervisor, name: ADK.SessionSupervisor, strategy: :one_for_one})
    end

    unless Process.whereis(ADK.SessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: ADK.SessionRegistry})
    end

    unless Process.whereis(ADK.Plugin.Registry) do
      start_supervised!(ADK.Plugin.Registry)
    end

    :ok
  end

  describe "plugin behaviour" do
    test "init/1 returns ok with state" do
      assert {:ok, state} = ReflectRetry.init(max_retries: 2)
      assert state.max_retries == 2
      assert state.retry_counts == %{}
    end

    test "init/1 with defaults" do
      assert {:ok, state} = ReflectRetry.init([])
      assert state.max_retries == 3
    end

    test "before_run/2 passes through" do
      {:ok, state} = ReflectRetry.init([])
      ctx = %ADK.Context{invocation_id: "test", agent: nil}
      assert {:cont, ^ctx, ^state} = ReflectRetry.before_run(ctx, state)
    end

    test "after_run/3 passes through when no errors" do
      {:ok, state} = ReflectRetry.init([])
      events = [ADK.Event.new(%{author: "bot", content: %{parts: [%{text: "ok"}]}})]
      ctx = %ADK.Context{invocation_id: "test", agent: nil}

      {result, _state} = ReflectRetry.after_run(events, ctx, state)
      assert length(result) == 1
      assert hd(result).author == "bot"
    end

    test "after_run/3 detects error events" do
      assert ReflectRetry.has_error?(%ADK.Event{error: "something broke"})
      refute ReflectRetry.has_error?(%ADK.Event{error: nil, author: "bot"})
    end

    test "after_run/3 retries on error with mock agent" do
      {:ok, state} = ReflectRetry.init(max_retries: 2)

      # Create a mock agent that succeeds on retry
      call_count = :counters.new(1, [:atomics])
      # Pre-set to 1 so the first agent call (triggered by after_run) succeeds
      :counters.put(call_count, 1, 1)

      agent =
        ADK.Agent.Custom.new(
          name: "retry_agent",
          run_fn: fn _agent, _ctx ->
            count = :counters.get(call_count, 1) + 1
            :counters.put(call_count, 1, count)

            if count <= 1 do
              [ADK.Event.new(%{author: "retry_agent", error: "temporary failure"})]
            else
              [ADK.Event.new(%{author: "retry_agent", content: %{parts: [%{text: "success!"}]}})]
            end
          end
        )

      # Start a session
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "reflect-retry-#{System.unique_integer([:positive])}"
        )

      ctx = %ADK.Context{
        invocation_id: "inv-retry-test",
        agent: agent,
        session_pid: session_pid
      }

      error_events = [ADK.Event.new(%{author: "retry_agent", error: "temporary failure"})]

      {result_events, new_state} = ReflectRetry.after_run(error_events, ctx, state)

      # Should have retried and succeeded
      success_events = Enum.filter(result_events, fn e -> e.error == nil && ADK.Event.text(e) end)
      assert Enum.any?(success_events, fn e -> ADK.Event.text(e) == "success!" end)

      # Retry count should be incremented
      assert Map.get(new_state.retry_counts, "inv-retry-test") == 1

      GenServer.stop(session_pid)
    end

    test "after_run/3 respects max_retries" do
      {:ok, state} = ReflectRetry.init(max_retries: 1)

      # Agent that always fails
      agent =
        ADK.Agent.Custom.new(
          name: "always_fail",
          run_fn: fn _agent, _ctx ->
            [ADK.Event.new(%{author: "always_fail", error: "permanent failure"})]
          end
        )

      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "reflect-max-#{System.unique_integer([:positive])}"
        )

      ctx = %ADK.Context{
        invocation_id: "inv-max-test",
        agent: agent,
        session_pid: session_pid
      }

      error_events = [ADK.Event.new(%{author: "always_fail", error: "permanent failure"})]

      {result_events, new_state} = ReflectRetry.after_run(error_events, ctx, state)

      # All events should still have errors (retried once but still failed, then gave up)
      assert Map.get(new_state.retry_counts, "inv-max-test") == 1

      GenServer.stop(session_pid)
    end
  end

  describe "integration with Runner via Plugin.Registry" do
    test "registered plugin is picked up by Runner" do
      # Register the plugin
      ADK.Plugin.register({ADK.Plugin.ReflectRetry, max_retries: 1})

      plugins = ADK.Plugin.list()
      assert Enum.any?(plugins, fn {mod, _} -> mod == ADK.Plugin.ReflectRetry end)
    end
  end
end
