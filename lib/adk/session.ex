defmodule ADK.Session do
  @moduledoc """
  Session GenServer — one process per active session.

  Holds session state (key-value map) and event history.

  ## Persistence

  Sessions can optionally persist to a store. Pass the `:store` option
  to `start_link/1`:

      ADK.Session.start_link(
        app_name: "my_app",
        user_id: "user1",
        session_id: "sess1",
        store: {ADK.Session.Store.InMemory, []}
      )

  On init, the session will attempt to load existing data from the store.
  Call `save/1` to persist the current state, or configure `auto_save: true`
  to auto-save on process termination.
  """
  use GenServer

  defstruct [:id, :app_name, :user_id, state: %{}, events: []]

  @type t :: %__MODULE__{
          id: String.t(),
          app_name: String.t(),
          user_id: String.t(),
          state: map(),
          events: [ADK.Event.t()]
        }

  # --- Client API ---

  @doc "Start a session process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || via_tuple(opts[:app_name], opts[:user_id], opts[:session_id])
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a session under `ADK.SessionSupervisor`.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_supervised(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_supervised(opts) do
    DynamicSupervisor.start_child(ADK.SessionSupervisor, {__MODULE__, opts})
  end

  @doc """
  Look up an existing session by app_name, user_id, and session_id.

  Returns `{:ok, pid}` or `:error`.
  """
  @spec lookup(String.t(), String.t(), String.t()) :: {:ok, pid()} | :error
  def lookup(app_name, user_id, session_id) do
    case Registry.lookup(ADK.SessionRegistry, {app_name, user_id, session_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp via_tuple(nil, _, _), do: nil
  defp via_tuple(_, nil, _), do: nil
  defp via_tuple(_, _, nil), do: nil
  defp via_tuple(app_name, user_id, session_id) do
    {:via, Registry, {ADK.SessionRegistry, {app_name, user_id, session_id}}}
  end

  @doc "Get the full session struct."
  @spec get(pid() | atom()) :: {:ok, t()}
  def get(pid), do: GenServer.call(pid, :get)

  @doc "Get all session state as a map."
  @spec get_all_state(pid() | atom()) :: map()
  def get_all_state(pid), do: GenServer.call(pid, :get_all_state)

  @doc "Get a value from session state."
  @spec get_state(pid() | atom(), term()) :: term() | nil
  def get_state(pid, key), do: GenServer.call(pid, {:get_state, key})

  @doc "Put a value into session state."
  @spec put_state(pid() | atom(), term(), term()) :: :ok
  def put_state(pid, key, value), do: GenServer.call(pid, {:put_state, key, value})

  @doc "Append an event to the session."
  @spec append_event(pid() | atom(), ADK.Event.t()) :: :ok
  def append_event(pid, event), do: GenServer.call(pid, {:append_event, event})

  @doc "Get all events from the session."
  @spec get_events(pid() | atom()) :: [ADK.Event.t()]
  def get_events(pid), do: GenServer.call(pid, :get_events)

  @doc "Persist the current session state to the configured store."
  @spec save(pid() | atom()) :: :ok | {:error, term()}
  def save(pid), do: GenServer.call(pid, :save)

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    store = opts[:store]
    auto_save = opts[:auto_save] || false

    session_id = opts[:session_id] || generate_id()
    app_name = opts[:app_name] || "default"
    user_id = opts[:user_id] || "default"

    session =
      case maybe_load(store, app_name, user_id, session_id) do
        {:ok, data} ->
          %__MODULE__{
            id: data[:id] || session_id,
            app_name: data[:app_name] || app_name,
            user_id: data[:user_id] || user_id,
            state: deserialize_state(data[:state] || %{}),
            events: deserialize_events(data[:events] || [])
          }

        _ ->
          %__MODULE__{
            id: session_id,
            app_name: app_name,
            user_id: user_id,
            state: opts[:initial_state] || %{},
            events: []
          }
      end

    {:ok, %{session: session, store: store, auto_save: auto_save}}
  end

  @impl true
  def handle_call(:get, _from, %{session: session} = state) do
    {:reply, {:ok, session}, state}
  end

  def handle_call(:get_all_state, _from, %{session: session} = state) do
    {:reply, session.state, state}
  end

  def handle_call({:get_state, key}, _from, %{session: session} = state) do
    {:reply, Map.get(session.state, key), state}
  end

  def handle_call({:put_state, key, value}, _from, %{session: session} = state) do
    new_session = %{session | state: Map.put(session.state, key, value)}
    {:reply, :ok, %{state | session: new_session}}
  end

  def handle_call({:append_event, event}, _from, %{session: session} = state) do
    # Apply state delta if present
    new_state =
      case event.actions do
        %{state_delta: delta} when delta != %{} ->
          ADK.State.Delta.apply_delta(session.state, delta)

        _ ->
          session.state
      end

    new_session = %{session | state: new_state, events: session.events ++ [event]}
    {:reply, :ok, %{state | session: new_session}}
  end

  def handle_call(:get_events, _from, %{session: session} = state) do
    {:reply, session.events, state}
  end

  def handle_call(:save, _from, %{session: session, store: store} = state) do
    result = do_save(store, session)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{session: session, store: store, auto_save: true}) do
    do_save(store, session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Private Helpers ---

  defp maybe_load(nil, _app, _user, _id), do: :no_store
  defp maybe_load({mod, _opts}, app, user, id), do: mod.load(app, user, id)

  defp do_save(nil, _session), do: {:error, :no_store}
  defp do_save({mod, _opts}, session), do: mod.save(session)

  defp deserialize_state(state) when is_map(state) do
    # Keep string keys as-is to avoid atom table exhaustion from untrusted input.
    # Users should use string keys or convert explicitly with known atoms.
    state
  end

  defp deserialize_events(events) when is_list(events) do
    Enum.map(events, &deserialize_event/1)
  end

  defp deserialize_event(%ADK.Event{} = event), do: event

  defp deserialize_event(data) when is_map(data) do
    timestamp =
      case data[:timestamp] do
        nil -> nil
        %DateTime{} = dt -> dt
        ts when is_binary(ts) ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _} -> dt
            _ -> nil
          end
      end

    actions =
      case data[:actions] do
        %ADK.EventActions{} = a -> a
        a when is_map(a) ->
          %ADK.EventActions{
            state_delta: a[:state_delta] || %{},
            transfer_to_agent: a[:transfer_to_agent],
            escalate: a[:escalate] || false
          }
        _ -> %ADK.EventActions{}
      end

    %ADK.Event{
      id: data[:id],
      invocation_id: data[:invocation_id],
      author: data[:author],
      branch: data[:branch],
      timestamp: timestamp,
      content: data[:content],
      partial: data[:partial] || false,
      actions: actions,
      function_calls: data[:function_calls],
      function_responses: data[:function_responses],
      error: data[:error]
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
