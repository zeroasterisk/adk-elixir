defmodule ADK.LLM.Gateway.KeyPoolTest do
  use ExUnit.Case, async: true

  alias ADK.LLM.Gateway.{Auth, KeyPool}

  defp make_keys(n) do
    for i <- 1..n, do: %Auth{type: :api_key, source: {:static, "key-#{i}"}, resolved_token: "key-#{i}"}
  end

  defp start_pool(keys, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :round_robin)
    {:ok, pool} = KeyPool.start_link(keys: keys, strategy: strategy)
    pool
  end

  describe "round_robin" do
    test "cycles through keys" do
      pool = start_pool(make_keys(3))
      {:ok, {0, _}} = KeyPool.next_key(pool)
      {:ok, {1, _}} = KeyPool.next_key(pool)
      {:ok, {2, _}} = KeyPool.next_key(pool)
      {:ok, {0, _}} = KeyPool.next_key(pool)
    end

    test "skips rate-limited keys" do
      pool = start_pool(make_keys(3))
      {:ok, {0, _}} = KeyPool.next_key(pool)
      KeyPool.record_rate_limited(pool, 1)
      # Allow cast to process
      :timer.sleep(10)
      {:ok, {2, _}} = KeyPool.next_key(pool)
    end
  end

  describe "least_used" do
    test "picks lowest usage key" do
      pool = start_pool(make_keys(3), strategy: :least_used)
      # First call picks key 0 (all at 0)
      {:ok, {0, _}} = KeyPool.next_key(pool)
      # Now key 0 has count 1, keys 1&2 have 0, should pick 1
      {:ok, {1, _}} = KeyPool.next_key(pool)
      {:ok, {2, _}} = KeyPool.next_key(pool)
      # All at 1, picks 0 again
      {:ok, {0, _}} = KeyPool.next_key(pool)
    end
  end

  describe "rate limiting" do
    test "record_rate_limited marks key unavailable" do
      pool = start_pool(make_keys(1))
      {:ok, {0, _}} = KeyPool.next_key(pool)
      KeyPool.record_rate_limited(pool, 0)
      :timer.sleep(10)
      assert {:error, :all_keys_rate_limited} = KeyPool.next_key(pool)
    end

    test "record_success clears penalty" do
      pool = start_pool(make_keys(1))
      KeyPool.record_rate_limited(pool, 0)
      :timer.sleep(10)
      KeyPool.record_success(pool, 0)
      :timer.sleep(10)
      assert {:ok, {0, _}} = KeyPool.next_key(pool)
    end
  end

  describe "stats/1" do
    test "returns per-key counters" do
      pool = start_pool(make_keys(2))
      {:ok, {0, _}} = KeyPool.next_key(pool)
      KeyPool.record_usage(pool, 0, %{tokens: 100})
      :timer.sleep(10)
      stats = KeyPool.stats(pool)
      assert stats[0].request_count == 1
      assert stats[0].token_count == 100
      assert stats[1].request_count == 0
    end
  end

  describe "reset/1" do
    test "clears all state" do
      pool = start_pool(make_keys(2))
      {:ok, {0, _}} = KeyPool.next_key(pool)
      KeyPool.record_rate_limited(pool, 0)
      :timer.sleep(10)
      KeyPool.reset(pool)
      stats = KeyPool.stats(pool)
      assert stats[0].request_count == 0
      assert {:ok, {0, _}} = KeyPool.next_key(pool)
    end
  end
end
