defmodule ADK.Plugin.LoggingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ADK.Plugin.Logging

  # -- init --

  test "init with defaults" do
    assert {:ok, state} = Logging.init([])
    assert state.level == :info
    assert state.include_events == false
    assert state.start_times == %{}
  end

  test "init with keyword config" do
    assert {:ok, state} = Logging.init(level: :debug, include_events: true)
    assert state.level == :debug
    assert state.include_events == true
  end

  test "init with map config" do
    assert {:ok, state} = Logging.init(%{level: :warning})
    assert state.level == :warning
  end

  test "init with non-list/map falls back to defaults" do
    assert {:ok, state} = Logging.init(:whatever)
    assert state.level == :info
  end

  # -- before_run --

  test "before_run logs start and records start time" do
    {:ok, state} = Logging.init([])

    agent = ADK.Agent.Custom.new(name: "test_agent", run_fn: fn _, _ -> [] end)
    ctx = %ADK.Context{invocation_id: "inv-1", agent: agent}

    log =
      capture_log(fn ->
        {:cont, ^ctx, new_state} = Logging.before_run(ctx, state)
        assert Map.has_key?(new_state.start_times, "inv-1")
      end)

    assert log =~ "[ADK.Plugin.Logging] run start agent=test_agent invocation=inv-1"
  end

  test "before_run with nil agent uses unknown" do
    {:ok, state} = Logging.init([])
    ctx = %ADK.Context{invocation_id: "inv-2", agent: nil}

    log =
      capture_log(fn ->
        {:cont, ^ctx, _state} = Logging.before_run(ctx, state)
      end)

    assert log =~ "agent=unknown"
  end

  # -- after_run --

  test "after_run logs end with counts and elapsed time" do
    {:ok, state} = Logging.init([])

    agent = ADK.Agent.Custom.new(name: "test_agent", run_fn: fn _, _ -> [] end)
    ctx = %ADK.Context{invocation_id: "inv-3", agent: agent}

    # Simulate before_run to record start time
    state = put_in(state.start_times["inv-3"], System.monotonic_time(:millisecond) - 42)

    events = [
      ADK.Event.new(%{author: "a", content: %{parts: [%{text: "ok"}]}}),
      ADK.Event.new(%{author: "a", error: "oops"})
    ]

    log =
      capture_log(fn ->
        {result, new_state} = Logging.after_run(events, ctx, state)
        assert result == events
        refute Map.has_key?(new_state.start_times, "inv-3")
      end)

    assert log =~ "[ADK.Plugin.Logging] run end agent=test_agent events=2 errors=1"
    assert log =~ "elapsed_ms="
  end

  test "after_run with include_events logs each event" do
    {:ok, state} = Logging.init(include_events: true)

    agent = ADK.Agent.Custom.new(name: "verbose", run_fn: fn _, _ -> [] end)
    ctx = %ADK.Context{invocation_id: "inv-4", agent: agent}

    events = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "hello"}]}})]

    log =
      capture_log(fn ->
        {_result, _state} = Logging.after_run(events, ctx, state)
      end)

    assert log =~ "[ADK.Plugin.Logging] event:"
  end

  test "after_run at debug level" do
    {:ok, state} = Logging.init(level: :debug)

    agent = ADK.Agent.Custom.new(name: "dbg", run_fn: fn _, _ -> [] end)
    ctx = %ADK.Context{invocation_id: "inv-5", agent: agent}
    events = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "ok"}]}})]

    log =
      capture_log(fn ->
        Logging.after_run(events, ctx, state)
      end)

    assert log =~ "[ADK.Plugin.Logging] run end"
  end

  # -- Plugin behaviour --

  test "implements ADK.Plugin behaviour callbacks" do
    Code.ensure_loaded!(Logging)
    assert function_exported?(Logging, :init, 1)
    assert function_exported?(Logging, :before_run, 2)
    assert function_exported?(Logging, :after_run, 3)
  end
end
