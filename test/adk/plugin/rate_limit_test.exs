defmodule ADK.Plugin.RateLimitTest do
  use ExUnit.Case, async: true

  alias ADK.Plugin.RateLimit

  # -- init --

  test "init with defaults" do
    assert {:ok, state} = RateLimit.init([])
    assert state.limit == 100
    assert state.window_ms == 60_000
    assert state.call_log == %{}
  end

  test "init with keyword config" do
    key_fn = fn ctx -> ctx.user_id end
    assert {:ok, state} = RateLimit.init(limit: 5, window_ms: 1000, key_fn: key_fn)
    assert state.limit == 5
    assert state.window_ms == 1000
    assert state.key_fn == key_fn
  end

  test "init with map config" do
    assert {:ok, state} = RateLimit.init(%{limit: 10})
    assert state.limit == 10
  end

  # -- before_run: under limit --

  test "before_run allows calls under the limit" do
    {:ok, state} = RateLimit.init(limit: 3, window_ms: 60_000)

    agent = ADK.Agent.Custom.new(name: "test_agent", run_fn: fn _, _ -> [] end)
    ctx = %ADK.Context{invocation_id: "inv-1", agent: agent}

    {:cont, ^ctx, state} = RateLimit.before_run(ctx, state)
    {:cont, ^ctx, state} = RateLimit.before_run(ctx, state)
    {:cont, ^ctx, _state} = RateLimit.before_run(ctx, state)
  end

  # -- before_run: over limit --

  test "before_run halts when limit is exceeded" do
    {:ok, state} = RateLimit.init(limit: 2, window_ms: 60_000)

    agent = ADK.Agent.Custom.new(name: "test_agent", run_fn: fn _, _ -> [] end)
    ctx = %ADK.Context{invocation_id: "inv-1", agent: agent}

    {:cont, ^ctx, state} = RateLimit.before_run(ctx, state)
    {:cont, ^ctx, state} = RateLimit.before_run(ctx, state)
    {:halt, {:error, :rate_limited}, _state} = RateLimit.before_run(ctx, state)
  end

  # -- before_run: window expiry --

  test "before_run prunes expired timestamps" do
    {:ok, state} = RateLimit.init(limit: 1, window_ms: 50)

    agent = ADK.Agent.Custom.new(name: "test_agent", run_fn: fn _, _ -> [] end)
    ctx = %ADK.Context{invocation_id: "inv-1", agent: agent}

    {:cont, ^ctx, state} = RateLimit.before_run(ctx, state)
    {:halt, {:error, :rate_limited}, _state} = RateLimit.before_run(ctx, state)

    # Wait for window to expire
    Process.sleep(60)

    {:cont, ^ctx, _state} = RateLimit.before_run(ctx, state)
  end

  # -- before_run: custom key_fn --

  test "before_run buckets by key_fn" do
    key_fn = fn ctx -> ctx.user_id || "anon" end
    {:ok, state} = RateLimit.init(limit: 1, window_ms: 60_000, key_fn: key_fn)

    agent = ADK.Agent.Custom.new(name: "test", run_fn: fn _, _ -> [] end)
    ctx_a = %ADK.Context{invocation_id: "inv-1", agent: agent, user_id: "alice"}
    ctx_b = %ADK.Context{invocation_id: "inv-2", agent: agent, user_id: "bob"}

    # Alice uses her quota
    {:cont, ^ctx_a, state} = RateLimit.before_run(ctx_a, state)
    # Alice is now rate limited
    {:halt, {:error, :rate_limited}, state} = RateLimit.before_run(ctx_a, state)
    # Bob is still fine (different bucket)
    {:cont, ^ctx_b, _state} = RateLimit.before_run(ctx_b, state)
  end

  # -- after_run --

  test "after_run is a no-op pass-through" do
    {:ok, state} = RateLimit.init([])
    ctx = %ADK.Context{invocation_id: "inv-1"}
    events = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "ok"}]}})]

    {result, new_state} = RateLimit.after_run(events, ctx, state)
    assert result == events
    assert new_state == state
  end

  # -- default key_fn --

  test "default key uses agent name" do
    {:ok, state} = RateLimit.init(limit: 1, window_ms: 60_000)

    agent_a = ADK.Agent.Custom.new(name: "agent_a", run_fn: fn _, _ -> [] end)
    agent_b = ADK.Agent.Custom.new(name: "agent_b", run_fn: fn _, _ -> [] end)
    ctx_a = %ADK.Context{invocation_id: "inv-1", agent: agent_a}
    ctx_b = %ADK.Context{invocation_id: "inv-2", agent: agent_b}

    {:cont, ^ctx_a, state} = RateLimit.before_run(ctx_a, state)
    {:halt, {:error, :rate_limited}, state} = RateLimit.before_run(ctx_a, state)
    # Different agent — different bucket
    {:cont, ^ctx_b, _state} = RateLimit.before_run(ctx_b, state)
  end

  # -- Plugin behaviour --

  test "implements ADK.Plugin behaviour callbacks" do
    Code.ensure_loaded!(RateLimit)
    assert function_exported?(RateLimit, :init, 1)
    assert function_exported?(RateLimit, :before_run, 2)
    assert function_exported?(RateLimit, :after_run, 3)
  end
end
