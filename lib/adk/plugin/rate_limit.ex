defmodule ADK.Plugin.RateLimit do
  @moduledoc """
  A sliding-window rate limiter plugin.

  Tracks call timestamps per bucket key and halts execution when the limit
  is exceeded within the configured time window.

  ## Configuration

      # Default — 100 calls per minute, bucketed by agent name
      ADK.Plugin.register({ADK.Plugin.RateLimit, []})

      # Custom — 10 calls per 30 seconds, bucketed by user ID
      ADK.Plugin.register({ADK.Plugin.RateLimit,
        limit: 10,
        window_ms: 30_000,
        key_fn: fn context -> context.user_id || "anonymous" end
      })

  ## Options

  - `:limit` — maximum calls allowed in the window. Default `100`.
  - `:window_ms` — window size in milliseconds. Default `60_000` (1 minute).
  - `:key_fn` — function `context -> key` to bucket by. Default uses agent name or `"global"`.

  ## Behaviour

  - `before_run/2` — prunes expired timestamps, checks if the limit is exceeded.
    Returns `{:halt, {:error, :rate_limited}, state}` when over limit.
  - `after_run/3` — no-op pass-through.
  """

  @behaviour ADK.Plugin

  @default_limit 100
  @default_window_ms 60_000

  @type config :: [
          limit: pos_integer(),
          window_ms: pos_integer(),
          key_fn: (ADK.Context.t() -> term())
        ]

  @type state :: %{
          limit: pos_integer(),
          window_ms: pos_integer(),
          key_fn: (ADK.Context.t() -> term()),
          call_log: %{term() => [integer()]}
        }

  @impl true
  def init(config) when is_list(config) do
    {:ok,
     %{
       limit: Keyword.get(config, :limit, @default_limit),
       window_ms: Keyword.get(config, :window_ms, @default_window_ms),
       key_fn: Keyword.get(config, :key_fn, &default_key/1),
       call_log: %{}
     }}
  end

  def init(config) when is_map(config) do
    {:ok,
     %{
       limit: Map.get(config, :limit, @default_limit),
       window_ms: Map.get(config, :window_ms, @default_window_ms),
       key_fn: Map.get(config, :key_fn, &default_key/1),
       call_log: %{}
     }}
  end

  def init(_), do: init([])

  @impl true
  def before_run(context, state) do
    key = state.key_fn.(context)
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.window_ms

    # Prune old timestamps and get current count
    existing = Map.get(state.call_log, key, [])
    pruned = Enum.filter(existing, &(&1 > cutoff))

    if length(pruned) >= state.limit do
      new_state = put_in(state.call_log[key], pruned)
      {:halt, {:error, :rate_limited}, new_state}
    else
      new_state = put_in(state.call_log[key], [now | pruned])
      {:cont, context, new_state}
    end
  end

  @impl true
  def after_run(events, _context, state) do
    {events, state}
  end

  defp default_key(%{agent: %{name: name}}) when is_binary(name), do: name
  defp default_key(_), do: "global"
end
