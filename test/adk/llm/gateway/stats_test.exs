defmodule ADK.LLM.Gateway.StatsTest do
  use ExUnit.Case, async: false

  alias ADK.LLM.Gateway.Stats

  setup do
    # Stats uses a named ETS table, so we need to ensure it's started
    case Process.whereis(Stats) do
      nil -> {:ok, _} = Stats.start_link()
      _ -> :ok
    end

    Stats.reset()
    :ok
  end

  test "record_request updates counters" do
    Stats.record_request(:test_backend, 0, %{
      latency_ms: 100,
      tokens_in: 10,
      tokens_out: 20,
      status: :ok
    })

    stats = Stats.get_stats(:test_backend)
    assert stats.total_requests == 1
    assert stats.total_tokens == 30
  end

  test "get_stats returns aggregates" do
    for _ <- 1..5 do
      Stats.record_request(:agg_test, 0, %{
        latency_ms: 50,
        tokens_in: 5,
        tokens_out: 10,
        status: :ok
      })
    end

    stats = Stats.get_stats(:agg_test)
    assert stats.total_requests == 5
    assert stats.total_tokens == 75
  end

  test "rpm tracks rolling 60s window" do
    Stats.record_request(:rpm_test, 0, %{latency_ms: 10, tokens_in: 1, tokens_out: 1, status: :ok})

    stats = Stats.get_stats(:rpm_test)
    assert stats.rpm == 1
  end

  test "p50/p95 latency calculation" do
    for i <- 1..100 do
      Stats.record_request(:latency_test, 0, %{
        latency_ms: i,
        tokens_in: 0,
        tokens_out: 0,
        status: :ok
      })
    end

    stats = Stats.get_stats(:latency_test)
    assert stats.p50_latency == 50
    assert stats.p95_latency == 95
  end

  test "error_rate calculation" do
    for _ <- 1..80 do
      Stats.record_request(:err_test, 0, %{
        latency_ms: 10,
        tokens_in: 0,
        tokens_out: 0,
        status: :ok
      })
    end

    for _ <- 1..20 do
      Stats.record_request(:err_test, 0, %{
        latency_ms: 10,
        tokens_in: 0,
        tokens_out: 0,
        status: :error
      })
    end

    stats = Stats.get_stats(:err_test)
    assert_in_delta stats.error_rate, 0.2, 0.05
  end

  test "reset clears stats" do
    Stats.record_request(:reset_test, 0, %{
      latency_ms: 10,
      tokens_in: 1,
      tokens_out: 1,
      status: :ok
    })

    Stats.reset()
    stats = Stats.get_stats(:reset_test)
    assert stats.total_requests == 0
  end

  test "get_key_stats filters by key_index" do
    Stats.record_request(:key_test, 0, %{latency_ms: 10, tokens_in: 1, tokens_out: 1, status: :ok})

    Stats.record_request(:key_test, 1, %{latency_ms: 20, tokens_in: 2, tokens_out: 2, status: :ok})

    key0 = Stats.get_key_stats(:key_test, 0)
    assert key0.total_requests == 1
  end

  test "get_all_stats returns everything" do
    Stats.record_request(:all_a, 0, %{latency_ms: 10, tokens_in: 1, tokens_out: 1, status: :ok})
    Stats.record_request(:all_b, 0, %{latency_ms: 20, tokens_in: 2, tokens_out: 2, status: :ok})
    all = Stats.get_all_stats()
    assert Map.has_key?(all, :all_a)
    assert Map.has_key?(all, :all_b)
  end
end
