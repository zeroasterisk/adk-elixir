defmodule ADK.Plugin.Cache do
  @moduledoc """
  A simple in-memory response cache plugin using ETS.

  Caches agent run results keyed by user content, with configurable TTL
  and maximum cache size with LRU-style eviction.

  ## Configuration

      # Default — 5-minute TTL, hash of user message as key
      ADK.Plugin.register({ADK.Plugin.Cache, []})

      # Custom — 1-minute TTL, custom key function, max 500 entries
      ADK.Plugin.register({ADK.Plugin.Cache,
        ttl_ms: 60_000,
        max_size: 500,
        key_fn: fn context -> {context.user_id, context.user_content} end
      })

  ## Options

  - `:ttl_ms` — cache entry TTL in milliseconds. Default `300_000` (5 minutes).
  - `:key_fn` — function `context -> key` for cache lookup. Default uses
    `:erlang.phash2/1` on the user message text.
  - `:max_size` — max entries before oldest eviction. Default `1000`.

  ## Behaviour

  - `init/1` — creates an ETS table with a unique name.
  - `before_run/2` — computes cache key; returns cached events on hit (not expired).
  - `after_run/3` — stores result in cache with timestamp; evicts oldest if over max size.
  """

  @behaviour ADK.Plugin

  @default_ttl_ms 300_000
  @default_max_size 1000

  @type config :: [
          ttl_ms: pos_integer(),
          key_fn: (ADK.Context.t() -> term()),
          max_size: pos_integer()
        ]

  @type state :: %{
          ttl_ms: pos_integer(),
          key_fn: (ADK.Context.t() -> term()),
          max_size: pos_integer(),
          table: :ets.tid()
        }

  @impl true
  def init(config) when is_list(config) do
    table_name = :"adk_cache_#{:erlang.unique_integer([:positive])}"
    table = :ets.new(table_name, [:set, :public])

    {:ok,
     %{
       ttl_ms: Keyword.get(config, :ttl_ms, @default_ttl_ms),
       key_fn: Keyword.get(config, :key_fn, &default_key/1),
       max_size: Keyword.get(config, :max_size, @default_max_size),
       table: table
     }}
  end

  def init(config) when is_map(config) do
    table_name = :"adk_cache_#{:erlang.unique_integer([:positive])}"
    table = :ets.new(table_name, [:set, :public])

    {:ok,
     %{
       ttl_ms: Map.get(config, :ttl_ms, @default_ttl_ms),
       key_fn: Map.get(config, :key_fn, &default_key/1),
       max_size: Map.get(config, :max_size, @default_max_size),
       table: table
     }}
  end

  def init(_), do: init([])

  @impl true
  def before_run(context, state) do
    key = state.key_fn.(context)

    case :ets.lookup(state.table, key) do
      [{^key, events, timestamp}] ->
        now = System.monotonic_time(:millisecond)

        if now - timestamp <= state.ttl_ms do
          {:halt, events, state}
        else
          :ets.delete(state.table, key)
          {:cont, context, state}
        end

      [] ->
        {:cont, context, state}
    end
  end

  @impl true
  def after_run(events, context, state) do
    key = state.key_fn.(context)
    now = System.monotonic_time(:millisecond)

    # Evict oldest if at capacity
    maybe_evict(state)

    :ets.insert(state.table, {key, events, now})
    {events, state}
  end

  defp maybe_evict(state) do
    size = :ets.info(state.table, :size)

    if size >= state.max_size do
      # Find and delete the oldest entry
      oldest =
        :ets.foldl(
          fn {key, _events, ts}, acc ->
            case acc do
              nil -> {key, ts}
              {_k, oldest_ts} when ts < oldest_ts -> {key, ts}
              _ -> acc
            end
          end,
          nil,
          state.table
        )

      case oldest do
        {key, _ts} -> :ets.delete(state.table, key)
        nil -> :ok
      end
    end
  end

  defp default_key(%{user_content: content}) when is_map(content) do
    text = get_in(content, [:parts]) |> extract_text()
    :erlang.phash2(text)
  end

  defp default_key(%{user_content: content}) when is_binary(content) do
    :erlang.phash2(content)
  end

  defp default_key(_), do: :erlang.phash2("")

  defp extract_text(nil), do: ""

  defp extract_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{text: text} -> text
      _ -> ""
    end)
  end

  defp extract_text(_), do: ""
end
