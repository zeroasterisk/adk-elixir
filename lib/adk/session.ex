defmodule ADK.Session do
  @moduledoc """
  Session GenServer — one process per active session.

  Holds session state (key-value map) and event history.
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
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc "Get the full session struct."
  @spec get(pid() | atom()) :: {:ok, t()}
  def get(pid), do: GenServer.call(pid, :get)

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

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    session = %__MODULE__{
      id: opts[:session_id] || generate_id(),
      app_name: opts[:app_name] || "default",
      user_id: opts[:user_id] || "default",
      state: opts[:initial_state] || %{},
      events: []
    }

    {:ok, session}
  end

  @impl true
  def handle_call(:get, _from, session) do
    {:reply, {:ok, session}, session}
  end

  def handle_call({:get_state, key}, _from, session) do
    {:reply, Map.get(session.state, key), session}
  end

  def handle_call({:put_state, key, value}, _from, session) do
    {:reply, :ok, %{session | state: Map.put(session.state, key, value)}}
  end

  def handle_call({:append_event, event}, _from, session) do
    # Apply state delta if present
    new_state =
      case event.actions do
        %{state_delta: delta} when delta != %{} ->
          ADK.State.Delta.apply_delta(session.state, delta)

        _ ->
          session.state
      end

    new_session = %{session | state: new_state, events: session.events ++ [event]}
    {:reply, :ok, new_session}
  end

  def handle_call(:get_events, _from, session) do
    {:reply, session.events, session}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
