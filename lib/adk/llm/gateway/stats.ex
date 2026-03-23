defmodule ADK.LLM.Gateway.Stats do
  @moduledoc """
  ETS-based stats collection for LLM Gateway requests.

  ADK Elixir extension — no Python equivalent.
  """

  use GenServer

  @table :adk_llm_gateway_stats
  @max_entries_per_backend 1000

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec record_request(atom(), non_neg_integer(), map()) :: :ok
  def record_request(backend_id, key_index, data) do
    entry = %{
      backend_id: backend_id,
      key_index: key_index,
      latency_ms: Map.get(data, :latency_ms, 0),
      tokens_in: Map.get(data, :tokens_in, 0),
      tokens_out: Map.get(data, :tokens_out, 0),
      status: Map.get(data, :status, :ok),
      timestamp: System.monotonic_time(:millisecond)
    }

    key = {backend_id, System.unique_integer([:monotonic, :positive])}
    :ets.insert(@table, {key, entry})
    prune(backend_id)
    :ok
  end

  @spec get_stats(atom()) :: map()
  def get_stats(backend_id) do
    entries = entries_for(backend_id)
    aggregate(entries)
  end

  @spec get_key_stats(atom(), non_neg_integer()) :: map()
  def get_key_stats(backend_id, key_index) do
    entries = entries_for(backend_id) |> Enum.filter(&(&1.key_index == key_index))
    aggregate(entries)
  end

  @spec get_all_stats() :: map()
  def get_all_stats do
    all = :ets.tab2list(@table)
    all
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.group_by(& &1.backend_id)
    |> Map.new(fn {bid, entries} -> {bid, aggregate(entries)} end)
  end

  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # -- GenServer --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:ordered_set, :public, :named_table])
    {:ok, %{table: table}}
  end

  # -- Private --

  defp entries_for(backend_id) do
    # Match all entries for this backend
    match_spec = [{{{backend_id, :_}, :"$1"}, [], [:"$1"]}]
    :ets.select(@table, match_spec)
  end

  defp prune(backend_id) do
    keys =
      :ets.select(@table, [{{{backend_id, :"$1"}, :_}, [], [:"$1"]}])
      |> Enum.sort()

    if length(keys) > @max_entries_per_backend do
      to_delete = Enum.take(keys, length(keys) - @max_entries_per_backend)
      Enum.each(to_delete, fn seq -> :ets.delete(@table, {backend_id, seq}) end)
    end
  end

  defp aggregate([]), do: %{total_requests: 0, total_tokens: 0, rpm: 0, tpm: 0, error_rate: 0.0, p50_latency: 0, p95_latency: 0}

  defp aggregate(entries) do
    now = System.monotonic_time(:millisecond)
    window_60s = now - 60_000

    recent_60 = Enum.filter(entries, &(&1.timestamp >= window_60s))
    last_100 = entries |> Enum.sort_by(& &1.timestamp, :desc) |> Enum.take(100)

    total_tokens = Enum.sum(Enum.map(entries, &(&1.tokens_in + &1.tokens_out)))
    tokens_60 = Enum.sum(Enum.map(recent_60, &(&1.tokens_in + &1.tokens_out)))

    errors_100 = Enum.count(last_100, &(&1.status != :ok))
    error_rate = if last_100 == [], do: 0.0, else: errors_100 / length(last_100)

    latencies = last_100 |> Enum.map(& &1.latency_ms) |> Enum.sort()

    %{
      total_requests: length(entries),
      total_tokens: total_tokens,
      rpm: length(recent_60),
      tpm: tokens_60,
      error_rate: error_rate,
      p50_latency: percentile(latencies, 0.5),
      p95_latency: percentile(latencies, 0.95)
    }
  end

  defp percentile([], _), do: 0
  defp percentile(sorted, p) do
    idx = max(0, round(p * length(sorted)) - 1)
    Enum.at(sorted, idx, 0)
  end
end
