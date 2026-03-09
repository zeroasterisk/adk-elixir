defmodule ADK.Plugin.ReflectRetryTest do
  use ExUnit.Case, async: true

  alias ADK.Plugin.ReflectRetry

  defp make_ctx(agent \\ nil) do
    agent = agent || ADK.Agent.Custom.new(
      name: "test_agent",
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(%{author: "test_agent", content: %{parts: [%{text: "ok"}]}})]
      end
    )

    %ADK.Context{invocation_id: "inv-test", agent: agent}
  end

  # -- init tests --

  test "init with keyword list config" do
    assert {:ok, state} = ReflectRetry.init(max_retries: 5)
    assert state.max_retries == 5
    assert state.retry_counts == %{}
  end

  test "init with map config" do
    assert {:ok, state} = ReflectRetry.init(%{max_retries: 2})
    assert state.max_retries == 2
  end

  test "init with default config" do
    assert {:ok, state} = ReflectRetry.init([])
    assert state.max_retries == 3
  end

  # -- before_run tests --

  test "before_run always continues" do
    {:ok, state} = ReflectRetry.init([])
    ctx = make_ctx()
    assert {:cont, ^ctx, ^state} = ReflectRetry.before_run(ctx, state)
  end

  # -- has_error? tests --

  test "has_error? detects error events" do
    error_event = ADK.Event.new(%{author: "agent", error: "something broke"})
    ok_event = ADK.Event.new(%{author: "agent", content: "fine"})

    assert ReflectRetry.has_error?(error_event)
    refute ReflectRetry.has_error?(ok_event)
    refute ReflectRetry.has_error?(%ADK.Event{error: nil})
  end

  # -- build_reflection_events tests --

  test "build_reflection_events creates informative events" do
    errors = [
      ADK.Event.new(%{author: "tool_agent", error: "timeout"}),
      ADK.Event.new(%{author: "api_agent", error: "rate limited"})
    ]

    [reflection] = ReflectRetry.build_reflection_events(errors, 1)

    assert reflection.author == "system"
    text = ADK.Event.text(reflection)
    assert text =~ "Attempt 1"
    assert text =~ "timeout"
    assert text =~ "rate limited"
    assert text =~ "try again"
  end

  # -- after_run tests --

  test "after_run passes through when no errors" do
    {:ok, state} = ReflectRetry.init([])
    ctx = make_ctx()
    events = [ADK.Event.new(%{author: "agent", content: "good"})]

    {result, new_state} = ReflectRetry.after_run(events, ctx, state)
    assert result == events
    assert new_state == state
  end

  test "after_run retries on error and succeeds" do
    # Agent that fails first call, succeeds on retry (when :last_error is in temp_state)
    call_count = :counters.new(1, [:atomics])

    agent = ADK.Agent.Custom.new(
      name: "flaky_agent",
      run_fn: fn _agent, ctx ->
        if ADK.Context.get_temp(ctx, :last_error) do
          # Retry - succeed
          [ADK.Event.new(%{author: "flaky_agent", content: %{parts: [%{text: "recovered"}]}})]
        else
          :counters.add(call_count, 1, 1)
          [ADK.Event.new(%{author: "flaky_agent", error: "first failure"})]
        end
      end
    )

    {:ok, state} = ReflectRetry.init(max_retries: 3)
    ctx = make_ctx(agent)
    error_events = [ADK.Event.new(%{author: "flaky_agent", error: "first failure"})]

    {result, _state} = ReflectRetry.after_run(error_events, ctx, state)

    # Should have reflection event + successful retry
    assert length(result) >= 2
    texts = Enum.map(result, &ADK.Event.text/1) |> Enum.filter(& &1)
    assert Enum.any?(texts, &(&1 =~ "recovered"))
    assert Enum.any?(texts, &(&1 =~ "Reflect & Retry"))
  end

  test "after_run stops after max_retries" do
    # Agent that always fails
    always_fail = ADK.Agent.Custom.new(
      name: "always_fail",
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(%{author: "always_fail", error: "permanent failure"})]
      end
    )

    {:ok, state} = ReflectRetry.init(max_retries: 2)
    ctx = make_ctx(always_fail)
    error_events = [ADK.Event.new(%{author: "always_fail", error: "permanent failure"})]

    {result, final_state} = ReflectRetry.after_run(error_events, ctx, state)

    # Should have reflection events from attempts + final error events
    error_results = Enum.filter(result, &ReflectRetry.has_error?/1)
    assert length(error_results) > 0

    # Should have used up retries
    assert Map.get(final_state.retry_counts, "inv-test", 0) >= 2
  end

  test "after_run with max_retries: 0 passes through errors immediately" do
    always_fail = ADK.Agent.Custom.new(
      name: "always_fail",
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(%{author: "always_fail", error: "fail"})]
      end
    )

    # Pre-set retry count to max
    state = %{max_retries: 0, retry_counts: %{}}
    ctx = make_ctx(always_fail)
    error_events = [ADK.Event.new(%{author: "always_fail", error: "fail"})]

    {result, _state} = ReflectRetry.after_run(error_events, ctx, state)
    assert result == error_events
  end

  # -- Integration with Plugin system --

  test "works as a proper Plugin module" do
    # Verify it implements the behaviour
    assert function_exported?(ReflectRetry, :init, 1)
    assert function_exported?(ReflectRetry, :before_run, 2)
    assert function_exported?(ReflectRetry, :after_run, 3)
  end
end
