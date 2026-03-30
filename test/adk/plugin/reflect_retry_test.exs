defmodule ADK.Plugin.ReflectRetryTest do
  use ExUnit.Case, async: true

  alias ADK.Plugin.ReflectRetry

  # -- init --

  test "init with defaults" do
    assert {:ok, state} = ReflectRetry.init([])
    assert state.max_retries == 3
    assert state.validator == nil
    assert state.retry_counts == %{}
  end

  test "init with keyword config" do
    v = fn _events -> :ok end
    assert {:ok, state} = ReflectRetry.init(max_retries: 5, validator: v)
    assert state.max_retries == 5
    assert state.validator == v
  end

  test "init with map config" do
    assert {:ok, state} = ReflectRetry.init(%{max_retries: 2})
    assert state.max_retries == 2
  end

  test "init with custom template" do
    assert {:ok, state} = ReflectRetry.init(reflection_template: "Try #{"{attempt}"}")
    assert state.reflection_template == "Try {attempt}"
  end

  # -- before_run --

  test "before_run always continues" do
    {:ok, state} = ReflectRetry.init([])
    ctx = %ADK.Context{invocation_id: "x"}
    assert {:cont, ^ctx, ^state} = ReflectRetry.before_run(ctx, state)
  end

  # -- has_error? --

  test "has_error? detects errors" do
    assert ReflectRetry.has_error?(%ADK.Event{error: "boom"})
    refute ReflectRetry.has_error?(%ADK.Event{error: nil})
    refute ReflectRetry.has_error?(%ADK.Event{})
  end

  # -- check_events --

  test "check_events returns :ok when no errors and no validator" do
    {:ok, state} = ReflectRetry.init([])
    events = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "ok"}]}})]
    assert :ok = ReflectRetry.check_events(events, state)
  end

  test "check_events detects error events" do
    {:ok, state} = ReflectRetry.init([])
    events = [ADK.Event.new(%{author: "a", error: "timeout"})]
    assert {:error, "timeout"} = ReflectRetry.check_events(events, state)
  end

  test "check_events uses custom validator" do
    validator = fn events ->
      text = events |> Enum.map_join(" ", &ADK.Event.text/1)
      if String.contains?(text, "bad"), do: {:error, "bad response"}, else: :ok
    end

    {:ok, state} = ReflectRetry.init(validator: validator)

    good = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "good stuff"}]}})]
    assert :ok = ReflectRetry.check_events(good, state)

    bad = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "this is bad"}]}})]
    assert {:error, "bad response"} = ReflectRetry.check_events(bad, state)
  end

  test "check_events: errors take priority over validator" do
    validator = fn _events -> :ok end
    {:ok, state} = ReflectRetry.init(validator: validator)
    events = [ADK.Event.new(%{author: "a", error: "crash"})]
    assert {:error, "crash"} = ReflectRetry.check_events(events, state)
  end

  # -- after_run with real agent flow --

  test "after_run passes through when validation succeeds" do
    {:ok, state} = ReflectRetry.init([])
    ctx = %ADK.Context{invocation_id: "ok-test"}
    events = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "fine"}]}})]

    {result, new_state} = ReflectRetry.after_run(events, ctx, state)
    assert result == events
    assert new_state.retry_counts == %{}
  end

  test "after_run retries on error and succeeds" do
    agent =
      ADK.Agent.Custom.new(
        name: "flaky",
        run_fn: fn _agent, ctx ->
          if ADK.Context.get_temp(ctx, :reflection_feedback) do
            [ADK.Event.new(%{author: "flaky", content: %{parts: [%{text: "recovered"}]}})]
          else
            [ADK.Event.new(%{author: "flaky", error: "oops"})]
          end
        end
      )

    {:ok, state} = ReflectRetry.init(max_retries: 3)
    ctx = %ADK.Context{invocation_id: "retry-test", agent: agent}
    error_events = [ADK.Event.new(%{author: "flaky", error: "oops"})]

    {result, new_state} = ReflectRetry.after_run(error_events, ctx, state)

    texts = Enum.map(result, &ADK.Event.text/1) |> Enum.filter(& &1)
    assert Enum.any?(texts, &(&1 =~ "recovered"))
    assert Enum.any?(texts, &(&1 =~ "Reflect & Retry"))
    assert new_state.retry_counts["retry-test:reflect_retry"] == 1
  end

  test "after_run retries on validation failure" do
    call_count = :counters.new(1, [:atomics])

    agent =
      ADK.Agent.Custom.new(
        name: "improving",
        run_fn: fn _agent, _ctx ->
          n = :counters.get(call_count, 1) + 1
          :counters.put(call_count, 1, n)
          text = if n >= 2, do: "detailed answer with facts", else: "I don't know"
          [ADK.Event.new(%{author: "improving", content: %{parts: [%{text: text}]}})]
        end
      )

    validator = fn events ->
      text = events |> Enum.map_join(" ", &ADK.Event.text/1)

      if String.contains?(text, "I don't know"),
        do: {:error, "Response was evasive"},
        else: :ok
    end

    {:ok, state} = ReflectRetry.init(max_retries: 3, validator: validator)
    ctx = %ADK.Context{invocation_id: "val-test", agent: agent}

    initial = [
      ADK.Event.new(%{author: "improving", content: %{parts: [%{text: "I don't know"}]}})
    ]

    {result, new_state} = ReflectRetry.after_run(initial, ctx, state)

    texts = Enum.map(result, &ADK.Event.text/1) |> Enum.filter(& &1)
    assert Enum.any?(texts, &(&1 =~ "detailed answer"))
    assert Enum.any?(texts, &(&1 =~ "Reflect & Retry"))
    assert new_state.retry_counts["val-test:reflect_retry"] >= 1
  end

  test "after_run exhausts retries on persistent failure" do
    agent =
      ADK.Agent.Custom.new(
        name: "stubborn",
        run_fn: fn _agent, _ctx ->
          [ADK.Event.new(%{author: "stubborn", error: "always broken"})]
        end
      )

    {:ok, state} = ReflectRetry.init(max_retries: 2)
    ctx = %ADK.Context{invocation_id: "exhaust-test", agent: agent}
    initial = [ADK.Event.new(%{author: "stubborn", error: "always broken"})]

    {result, new_state} = ReflectRetry.after_run(initial, ctx, state)

    # Should have tried max_retries times then given up
    assert new_state.retry_counts["exhaust-test:reflect_retry"] == 2
    # Final result still has errors
    assert Enum.any?(result, &ReflectRetry.has_error?/1)
  end

  test "after_run with max_retries: 0 passes through immediately" do
    {:ok, state} = ReflectRetry.init(max_retries: 0)
    ctx = %ADK.Context{invocation_id: "zero-test"}
    events = [ADK.Event.new(%{author: "a", error: "fail"})]

    {result, _state} = ReflectRetry.after_run(events, ctx, state)
    assert result == events
  end

  test "after_run uses custom reflection template" do
    agent =
      ADK.Agent.Custom.new(
        name: "templated",
        run_fn: fn _agent, ctx ->
          if ADK.Context.get_temp(ctx, :reflection_feedback) do
            [ADK.Event.new(%{author: "templated", content: %{parts: [%{text: "fixed"}]}})]
          else
            [ADK.Event.new(%{author: "templated", error: "bad"})]
          end
        end
      )

    {:ok, state} =
      ReflectRetry.init(
        max_retries: 2,
        reflection_template: "RETRY {attempt} of {max}: {reason}"
      )

    ctx = %ADK.Context{invocation_id: "tmpl-test", agent: agent}
    events = [ADK.Event.new(%{author: "templated", error: "bad"})]

    {result, _state} = ReflectRetry.after_run(events, ctx, state)

    texts = Enum.map(result, &ADK.Event.text/1) |> Enum.filter(& &1)
    assert Enum.any?(texts, &(&1 =~ "RETRY 1 of 2: bad"))
  end

  test "after_run with validator that checks for JSON" do
    call_count = :counters.new(1, [:atomics])

    agent =
      ADK.Agent.Custom.new(
        name: "json_agent",
        run_fn: fn _agent, _ctx ->
          n = :counters.get(call_count, 1) + 1
          :counters.put(call_count, 1, n)
          text = if n >= 2, do: ~s({"result": "success"}), else: "Here's my answer in plain text"
          [ADK.Event.new(%{author: "json_agent", content: %{parts: [%{text: text}]}})]
        end
      )

    validator = fn events ->
      text = events |> Enum.map_join("", &(ADK.Event.text(&1) || ""))

      case Jason.decode(text) do
        {:ok, _} -> :ok
        {:error, _} -> {:error, "Response must be valid JSON"}
      end
    end

    {:ok, state} = ReflectRetry.init(max_retries: 3, validator: validator)
    ctx = %ADK.Context{invocation_id: "json-test", agent: agent}
    initial = [ADK.Event.new(%{author: "json_agent", content: %{parts: [%{text: "plain text"}]}})]

    {result, _state} = ReflectRetry.after_run(initial, ctx, state)

    texts = Enum.map(result, &ADK.Event.text/1) |> Enum.filter(& &1)
    assert Enum.any?(texts, &(&1 =~ ~s("result")))
  end

  # -- Plugin system integration --

  test "implements ADK.Plugin behaviour callbacks" do
    # Force module load
    Code.ensure_loaded!(ReflectRetry)
    assert function_exported?(ReflectRetry, :init, 1)
    assert function_exported?(ReflectRetry, :before_run, 2)
    assert function_exported?(ReflectRetry, :after_run, 3)
  end
end
