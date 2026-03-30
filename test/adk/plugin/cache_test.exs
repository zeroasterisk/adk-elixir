defmodule ADK.Plugin.CacheTest do
  use ExUnit.Case, async: true

  alias ADK.Plugin.Cache

  # -- init --

  test "init with defaults creates ETS table" do
    assert {:ok, state} = Cache.init([])
    assert state.ttl_ms == 300_000
    assert state.max_size == 1000
    assert :ets.info(state.table) != :undefined
  end

  test "init with keyword config" do
    key_fn = fn ctx -> ctx.user_id end
    assert {:ok, state} = Cache.init(ttl_ms: 1000, max_size: 10, key_fn: key_fn)
    assert state.ttl_ms == 1000
    assert state.max_size == 10
  end

  test "init with map config" do
    assert {:ok, state} = Cache.init(%{ttl_ms: 5000})
    assert state.ttl_ms == 5000
  end

  # -- before_run: cache miss --

  test "before_run returns :cont on cache miss" do
    {:ok, state} = Cache.init([])

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      user_content: %{parts: [%{text: "hello"}]}
    }

    {:cont, ^ctx, _state} = Cache.before_run(ctx, state)
  end

  # -- before_run + after_run: miss then hit --

  test "cache miss → run → cache hit on second call" do
    {:ok, state} = Cache.init([])

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      user_content: %{parts: [%{text: "what is elixir?"}]}
    }

    events = [ADK.Event.new(%{author: "agent", content: %{parts: [%{text: "a language"}]}})]

    # First call: miss
    {:cont, ^ctx, state} = Cache.before_run(ctx, state)

    # Store result
    {^events, state} = Cache.after_run(events, ctx, state)

    # Second call: hit
    {:halt, cached_events, _state} = Cache.before_run(ctx, state)
    assert cached_events == events
  end

  # -- before_run: expired entry --

  test "expired cache entries are not returned" do
    {:ok, state} = Cache.init(ttl_ms: 30)

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      user_content: %{parts: [%{text: "expire me"}]}
    }

    events = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "cached"}]}})]

    {:cont, ^ctx, state} = Cache.before_run(ctx, state)
    {^events, state} = Cache.after_run(events, ctx, state)

    # Wait for TTL to expire
    Process.sleep(40)

    {:cont, ^ctx, _state} = Cache.before_run(ctx, state)
  end

  # -- after_run: eviction --

  test "evicts oldest entry when max_size is reached" do
    {:ok, state} = Cache.init(max_size: 2)

    events_a = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "answer a"}]}})]
    events_b = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "answer b"}]}})]
    events_c = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "answer c"}]}})]

    ctx_a = %ADK.Context{invocation_id: "1", user_content: %{parts: [%{text: "a"}]}}
    ctx_b = %ADK.Context{invocation_id: "2", user_content: %{parts: [%{text: "b"}]}}
    ctx_c = %ADK.Context{invocation_id: "3", user_content: %{parts: [%{text: "c"}]}}

    # Fill cache to max
    {_, state} = Cache.after_run(events_a, ctx_a, state)
    Process.sleep(1)
    {_, state} = Cache.after_run(events_b, ctx_b, state)

    # This should evict the oldest (a)
    {_, state} = Cache.after_run(events_c, ctx_c, state)

    # "a" should be evicted, "b" and "c" should remain
    assert :ets.info(state.table, :size) <= 3
  end

  # -- custom key_fn --

  test "custom key_fn is used for cache lookup" do
    key_fn = fn ctx -> ctx.user_id end
    {:ok, state} = Cache.init(key_fn: key_fn)

    ctx_alice = %ADK.Context{
      invocation_id: "1",
      user_id: "alice",
      user_content: %{parts: [%{text: "hi"}]}
    }

    ctx_bob = %ADK.Context{
      invocation_id: "2",
      user_id: "bob",
      user_content: %{parts: [%{text: "hi"}]}
    }

    events = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "hello"}]}})]

    {:cont, _, state} = Cache.before_run(ctx_alice, state)
    {_, state} = Cache.after_run(events, ctx_alice, state)

    # Same user_content but different user_id — should miss
    {:cont, _, _state} = Cache.before_run(ctx_bob, state)

    # Same user_id — should hit
    {:halt, ^events, _state} = Cache.before_run(ctx_alice, state)
  end

  # -- default key with string content --

  test "default key handles string user_content" do
    {:ok, state} = Cache.init([])

    ctx = %ADK.Context{invocation_id: "1", user_content: "hello plain text"}
    events = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "response"}]}})]

    {:cont, ^ctx, state} = Cache.before_run(ctx, state)
    {_, state} = Cache.after_run(events, ctx, state)
    {:halt, ^events, _state} = Cache.before_run(ctx, state)
  end

  test "default key handles nil user_content" do
    {:ok, state} = Cache.init([])
    ctx = %ADK.Context{invocation_id: "1", user_content: nil}

    {:cont, ^ctx, _state} = Cache.before_run(ctx, state)
  end

  # -- Plugin behaviour --

  test "implements ADK.Plugin behaviour callbacks" do
    Code.ensure_loaded!(Cache)
    assert function_exported?(Cache, :init, 1)
    assert function_exported?(Cache, :before_run, 2)
    assert function_exported?(Cache, :after_run, 3)
  end
end
