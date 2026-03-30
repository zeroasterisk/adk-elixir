defmodule ADK.LLM.Gateway.KeyPool do
  @moduledoc """
  GenServer managing multiple API keys for one logical backend with rotation strategies.

  ADK Elixir extension — no Python equivalent.
  """

  use GenServer

  alias ADK.LLM.Gateway.Auth

  @default_backoff_ms 5_000
  @max_backoff_ms 300_000

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    keys = Keyword.fetch!(opts, :keys)
    strategy = Keyword.get(opts, :strategy, :round_robin)
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, {keys, strategy}, gen_opts)
  end

  @spec next_key(GenServer.server()) ::
          {:ok, {non_neg_integer(), Auth.t()}} | {:error, :all_keys_rate_limited}
  def next_key(pool), do: GenServer.call(pool, :next_key)

  @spec record_usage(GenServer.server(), non_neg_integer(), map()) :: :ok
  def record_usage(pool, key_index, usage), do: GenServer.cast(pool, {:usage, key_index, usage})

  @spec record_rate_limited(GenServer.server(), non_neg_integer()) :: :ok
  def record_rate_limited(pool, key_index), do: GenServer.cast(pool, {:rate_limited, key_index})

  @spec record_success(GenServer.server(), non_neg_integer()) :: :ok
  def record_success(pool, key_index), do: GenServer.cast(pool, {:success, key_index})

  @spec stats(GenServer.server()) :: map()
  def stats(pool), do: GenServer.call(pool, :stats)

  @spec reset(GenServer.server()) :: :ok
  def reset(pool), do: GenServer.call(pool, :reset)

  # -- GenServer callbacks --

  @impl true
  def init({keys, strategy}) do
    key_states =
      keys
      |> Enum.with_index()
      |> Enum.map(fn {auth, idx} ->
        {idx,
         %{
           auth: auth,
           request_count: 0,
           token_count: 0,
           rate_limit_count: 0,
           last_used_at: nil,
           available_at: nil,
           backoff_ms: @default_backoff_ms
         }}
      end)
      |> Map.new()

    {:ok, %{keys: key_states, strategy: strategy, rr_index: 0}}
  end

  @impl true
  def handle_call(:next_key, _from, state) do
    now = System.monotonic_time(:millisecond)
    available = available_keys(state.keys, now)

    case pick_key(available, state) do
      nil ->
        {:reply, {:error, :all_keys_rate_limited}, state}

      {idx, key_state} ->
        new_keys =
          Map.update!(state.keys, idx, fn k ->
            %{k | request_count: k.request_count + 1, last_used_at: now}
          end)

        new_state = %{state | keys: new_keys, rr_index: idx + 1}
        {:reply, {:ok, {idx, key_state.auth}}, new_state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats =
      Map.new(state.keys, fn {idx, k} ->
        {idx,
         Map.take(k, [
           :request_count,
           :token_count,
           :rate_limit_count,
           :last_used_at,
           :available_at,
           :backoff_ms
         ])}
      end)

    {:reply, stats, state}
  end

  def handle_call(:reset, _from, state) do
    new_keys =
      Map.new(state.keys, fn {idx, k} ->
        {idx,
         %{
           k
           | request_count: 0,
             token_count: 0,
             rate_limit_count: 0,
             last_used_at: nil,
             available_at: nil,
             backoff_ms: @default_backoff_ms
         }}
      end)

    {:reply, :ok, %{state | keys: new_keys, rr_index: 0}}
  end

  @impl true
  def handle_cast({:usage, key_index, usage}, state) do
    tokens = Map.get(usage, :tokens, 0)

    new_keys =
      Map.update!(state.keys, key_index, fn k ->
        %{k | token_count: k.token_count + tokens}
      end)

    {:noreply, %{state | keys: new_keys}}
  end

  def handle_cast({:rate_limited, key_index}, state) do
    now = System.monotonic_time(:millisecond)

    new_keys =
      Map.update!(state.keys, key_index, fn k ->
        new_backoff = min(k.backoff_ms * 2, @max_backoff_ms)

        %{
          k
          | rate_limit_count: k.rate_limit_count + 1,
            available_at: now + k.backoff_ms,
            backoff_ms: new_backoff
        }
      end)

    {:noreply, %{state | keys: new_keys}}
  end

  def handle_cast({:success, key_index}, state) do
    new_keys =
      Map.update!(state.keys, key_index, fn k ->
        %{k | available_at: nil, backoff_ms: max(@default_backoff_ms, div(k.backoff_ms, 2))}
      end)

    {:noreply, %{state | keys: new_keys}}
  end

  # -- Private --

  defp available_keys(keys, now) do
    Enum.filter(keys, fn {_idx, k} ->
      k.available_at == nil or now >= k.available_at
    end)
  end

  defp pick_key([], _state), do: nil

  defp pick_key(available, %{strategy: :round_robin, rr_index: rr}) do
    sorted = Enum.sort_by(available, fn {idx, _} -> idx end)
    # Find first key with index >= rr_index, or wrap around
    Enum.find(sorted, hd(sorted), fn {idx, _} -> idx >= rr end)
  end

  defp pick_key(available, %{strategy: :least_used}) do
    Enum.min_by(available, fn {_idx, k} -> k.request_count end)
  end
end
