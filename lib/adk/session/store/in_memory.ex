defmodule ADK.Session.Store.InMemory do
  @moduledoc """
  ETS-backed in-memory session store.

  Sessions are stored in an ETS table and survive process restarts
  within the same BEAM node, but not node restarts.

  ## Usage

      # Start the store (usually in your supervision tree)
      ADK.Session.Store.InMemory.start_link([])

      # Use with sessions
      ADK.Session.start_link(
        app_name: "my_app",
        user_id: "user1",
        session_id: "sess1",
        store: {ADK.Session.Store.InMemory, []}
      )
  """

  use GenServer

  @behaviour ADK.Session.Store

  @table __MODULE__

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # --- Store Behaviour ---

  @impl ADK.Session.Store
  def load(app_name, user_id, session_id) do
    case :ets.lookup(@table, {app_name, user_id, session_id}) do
      [{_key, data}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @impl ADK.Session.Store
  def save(session) do
    key = {session.app_name, session.user_id, session.id}
    data = serialize_session(session)
    :ets.insert(@table, {key, data})
    :ok
  rescue
    ArgumentError -> {:error, :table_not_available}
  end

  @impl ADK.Session.Store
  def delete(app_name, user_id, session_id) do
    :ets.delete(@table, {app_name, user_id, session_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl ADK.Session.Store
  def list(app_name, user_id) do
    pattern = {{app_name, user_id, :"$1"}, :_}
    :ets.match(@table, pattern) |> List.flatten()
  rescue
    ArgumentError -> []
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public])
    {:ok, %{table: table}}
  end

  # --- Helpers ---

  defp serialize_session(session) do
    %{
      id: session.id,
      app_name: session.app_name,
      user_id: session.user_id,
      state: session.state,
      events: Enum.map(session.events, &serialize_event/1)
    }
  end

  defp serialize_event(%ADK.Event{} = event) do
    %{
      id: event.id,
      invocation_id: event.invocation_id,
      author: event.author,
      branch: event.branch,
      timestamp: event.timestamp && DateTime.to_iso8601(event.timestamp),
      content: event.content,
      partial: event.partial,
      actions: serialize_actions(event.actions),
      function_calls: event.function_calls,
      function_responses: event.function_responses,
      error: event.error
    }
  end

  defp serialize_event(event), do: event

  defp serialize_actions(%ADK.EventActions{} = actions) do
    %{
      state_delta: actions.state_delta,
      transfer_to_agent: actions.transfer_to_agent,
      escalate: actions.escalate
    }
  end

  defp serialize_actions(other), do: other
end
