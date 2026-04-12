defmodule ADK.Telemetry.SpanStore do
  @moduledoc """
  ETS-backed store for debug/trace span data.

  Stores span data in two ETS tables:
  - `adk_event_spans` — keyed by event_id, stores span attributes
  - `adk_session_spans` — keyed by session_id, stores lists of span data

  Provides the backing store for the `/debug/trace/` HTTP endpoints that match
  Python ADK's debug API.

  ## TTL

  Entries are automatically pruned after a configurable max age (default 30 minutes).
  Configure via application env:

      config :adk, :span_store_ttl_ms, 1_800_000

  ## Usage

      ADK.Telemetry.SpanStore.put_event_span("evt-123", %{name: "agent.run", ...})
      ADK.Telemetry.SpanStore.get_event_span("evt-123")
      #=> {:ok, %{name: "agent.run", ...}}

      ADK.Telemetry.SpanStore.put_session_span("sess-1", %{name: "agent.run", ...})
      ADK.Telemetry.SpanStore.get_session_spans("sess-1")
      #=> [%{name: "agent.run", ...}]
  """

  use GenServer

  @event_table :adk_event_spans
  @session_table :adk_session_spans
  @default_ttl_ms 30 * 60 * 1000
  @prune_interval_ms 60 * 1000

  # --- Public API ---

  @doc "Start the SpanStore as part of a supervision tree."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Store span attributes keyed by event_id."
  @spec put_event_span(String.t(), map()) :: :ok
  def put_event_span(event_id, attrs) when is_binary(event_id) and is_map(attrs) do
    :ets.insert(@event_table, {event_id, attrs, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "Retrieve span attributes for an event_id."
  @spec get_event_span(String.t()) :: {:ok, map()} | :not_found
  def get_event_span(event_id) when is_binary(event_id) do
    case :ets.lookup(@event_table, event_id) do
      [{^event_id, attrs, _ts}] -> {:ok, attrs}
      [] -> :not_found
    end
  end

  @doc "Store a span for a session_id (appended to existing list)."
  @spec put_session_span(String.t(), map()) :: :ok
  def put_session_span(session_id, span_data) when is_binary(session_id) and is_map(span_data) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@session_table, session_id) do
      [{^session_id, spans, _ts}] ->
        :ets.insert(@session_table, {session_id, spans ++ [span_data], now})

      [] ->
        :ets.insert(@session_table, {session_id, [span_data], now})
    end

    :ok
  end

  @doc "Retrieve all spans for a session_id."
  @spec get_session_spans(String.t()) :: [map()]
  def get_session_spans(session_id) when is_binary(session_id) do
    case :ets.lookup(@session_table, session_id) do
      [{^session_id, spans, _ts}] -> spans
      [] -> []
    end
  end

  @doc "Clear all stored spans (useful for testing)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@event_table)
    :ets.delete_all_objects(@session_table)
    :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@event_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@session_table, [:set, :public, :named_table, read_concurrency: true])

    schedule_prune()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    ttl_ms = ADK.Config.span_store_ttl_ms(@default_ttl_ms)
    cutoff = System.monotonic_time(:millisecond) - ttl_ms

    prune_table(@event_table, cutoff)
    prune_table(@session_table, cutoff)

    schedule_prune()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end

  defp prune_table(table, cutoff) do
    # Match spec: select keys where timestamp < cutoff
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end
end
