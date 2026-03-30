defmodule ADK.Session.Store.SQLite do
  @moduledoc """
  SQLite-backed session store with FTS5 full-text search on events.

  **⚡ Beyond Python ADK** — this store has no Python equivalent.

  Uses `exqlite` directly (no Ecto) for lightweight, self-initializing
  SQLite persistence with full-text search across event content.

  ## Usage

      # Start the store (usually in your supervision tree)
      ADK.Session.Store.SQLite.start_link(db_path: "/tmp/sessions.db")

      # Or in-memory for testing
      ADK.Session.Store.SQLite.start_link(db_path: ":memory:")

      # Use with sessions
      ADK.Session.start_link(
        app_name: "my_app",
        user_id: "user1",
        session_id: "sess1",
        store: {ADK.Session.Store.SQLite, [db_path: "/tmp/sessions.db"]}
      )

      # Full-text search across events
      ADK.Session.Store.SQLite.search("hello world", limit: 10)
      ADK.Session.Store.SQLite.search("deploy", app_name: "my_app")

      # Find sessions containing matching events
      ADK.Session.Store.SQLite.search_sessions("error")
  """

  use GenServer

  @behaviour ADK.Session.Store

  @default_name __MODULE__

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || @default_name
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # --- Store Behaviour ---

  @impl ADK.Session.Store
  @spec load(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def load(app_name, user_id, session_id) do
    GenServer.call(@default_name, {:load, app_name, user_id, session_id})
  end

  @impl ADK.Session.Store
  @spec save(ADK.Session.t()) :: :ok | {:error, term()}
  def save(session) do
    GenServer.call(@default_name, {:save, session})
  end

  @impl ADK.Session.Store
  @spec delete(String.t(), String.t(), String.t()) :: :ok
  def delete(app_name, user_id, session_id) do
    GenServer.call(@default_name, {:delete, app_name, user_id, session_id})
  end

  @impl ADK.Session.Store
  @spec list(String.t(), String.t()) :: [String.t()]
  def list(app_name, user_id) do
    GenServer.call(@default_name, {:list, app_name, user_id})
  end

  # --- FTS5 Search API ---

  @doc """
  Full-text search across event content using FTS5.

  Returns a list of event maps matching the search term.

  ## Options

    * `:app_name` - filter by app name
    * `:user_id` - filter by user id
    * `:session_id` - filter by session id
    * `:limit` - max results (default 50)
  """
  @spec search(String.t(), keyword()) :: [map()]
  def search(term, opts \\ []) do
    GenServer.call(@default_name, {:search, term, opts})
  end

  @doc """
  Returns distinct session IDs that contain events matching the search term.

  Accepts the same filter options as `search/2` (except `:limit`).
  """
  @spec search_sessions(String.t(), keyword()) :: [String.t()]
  def search_sessions(term, opts \\ []) do
    GenServer.call(@default_name, {:search_sessions, term, opts})
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    db_path = Keyword.fetch!(opts, :db_path)

    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} ->
        case init_schema(conn) do
          :ok -> {:ok, %{conn: conn}}
          {:error, reason} -> {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:load, app_name, user_id, session_id}, _from, state) do
    result = do_load(state.conn, app_name, user_id, session_id)
    {:reply, result, state}
  end

  def handle_call({:save, session}, _from, state) do
    result = do_save(state.conn, session)
    {:reply, result, state}
  end

  def handle_call({:delete, app_name, user_id, session_id}, _from, state) do
    result = do_delete(state.conn, app_name, user_id, session_id)
    {:reply, result, state}
  end

  def handle_call({:list, app_name, user_id}, _from, state) do
    result = do_list(state.conn, app_name, user_id)
    {:reply, result, state}
  end

  def handle_call({:search, term, opts}, _from, state) do
    result = do_search(state.conn, term, opts)
    {:reply, result, state}
  end

  def handle_call({:search_sessions, term, opts}, _from, state) do
    result = do_search_sessions(state.conn, term, opts)
    {:reply, result, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Exqlite.Sqlite3.close(state.conn)
  end

  # --- Schema ---

  defp init_schema(conn) do
    statements = [
      "PRAGMA journal_mode=WAL",
      """
      CREATE TABLE IF NOT EXISTS sessions (
        app_name TEXT NOT NULL,
        user_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        state_json TEXT NOT NULL DEFAULT '{}',
        updated_at TEXT NOT NULL,
        PRIMARY KEY (app_name, user_id, session_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        app_name TEXT NOT NULL,
        user_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        event_id TEXT,
        author TEXT,
        content_text TEXT,
        event_json TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_events_session ON events(app_name, user_id, session_id)",
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
        content_text,
        author,
        event_id,
        content=events,
        content_rowid=id
      )
      """,
      """
      CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
        INSERT INTO events_fts(rowid, content_text, author, event_id)
        VALUES (new.id, new.content_text, new.author, new.event_id);
      END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
        INSERT INTO events_fts(events_fts, rowid, content_text, author, event_id)
        VALUES ('delete', old.id, old.content_text, old.author, old.event_id);
      END
      """
    ]

    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case execute(conn, sql) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # --- Internal Operations ---

  defp do_load(conn, app_name, user_id, session_id) do
    sql =
      "SELECT state_json FROM sessions WHERE app_name = ?1 AND user_id = ?2 AND session_id = ?3"

    case query_one(conn, sql, [app_name, user_id, session_id]) do
      {:ok, [state_json]} ->
        state = Jason.decode!(state_json, keys: :atoms)
        events = load_events(conn, app_name, user_id, session_id)

        {:ok,
         %{
           id: session_id,
           app_name: app_name,
           user_id: user_id,
           state: state,
           events: events
         }}

      nil ->
        {:error, :not_found}
    end
  end

  defp load_events(conn, app_name, user_id, session_id) do
    sql =
      "SELECT event_json FROM events WHERE app_name = ?1 AND user_id = ?2 AND session_id = ?3 ORDER BY id ASC"

    query_all(conn, sql, [app_name, user_id, session_id])
    |> Enum.map(fn [json] -> Jason.decode!(json, keys: :atoms) end)
  end

  defp do_save(conn, session) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    state_json = Jason.encode!(session.state)

    with :ok <- execute(conn, "BEGIN"),
         :ok <-
           execute(
             conn,
             "INSERT OR REPLACE INTO sessions (app_name, user_id, session_id, state_json, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)",
             [session.app_name, session.user_id, session.id, state_json, now]
           ),
         :ok <-
           execute(
             conn,
             "DELETE FROM events WHERE app_name = ?1 AND user_id = ?2 AND session_id = ?3",
             [session.app_name, session.user_id, session.id]
           ),
         :ok <- insert_events(conn, session, now),
         :ok <- execute(conn, "COMMIT") do
      :ok
    else
      {:error, reason} ->
        execute(conn, "ROLLBACK")
        {:error, reason}
    end
  end

  defp insert_events(conn, session, now) do
    Enum.reduce_while(session.events, :ok, fn event, :ok ->
      {event_id, author, content_text, event_json} = serialize_event(event)

      case execute(
             conn,
             "INSERT INTO events (app_name, user_id, session_id, event_id, author, content_text, event_json, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
             [
               session.app_name,
               session.user_id,
               session.id,
               event_id,
               author,
               content_text,
               event_json,
               now
             ]
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp do_delete(conn, app_name, user_id, session_id) do
    with :ok <- execute(conn, "BEGIN"),
         :ok <-
           execute(
             conn,
             "DELETE FROM events WHERE app_name = ?1 AND user_id = ?2 AND session_id = ?3",
             [app_name, user_id, session_id]
           ),
         :ok <-
           execute(
             conn,
             "DELETE FROM sessions WHERE app_name = ?1 AND user_id = ?2 AND session_id = ?3",
             [app_name, user_id, session_id]
           ),
         :ok <- execute(conn, "COMMIT") do
      :ok
    else
      {:error, _} ->
        execute(conn, "ROLLBACK")
        :ok
    end
  end

  defp do_list(conn, app_name, user_id) do
    sql = "SELECT session_id FROM sessions WHERE app_name = ?1 AND user_id = ?2"

    query_all(conn, sql, [app_name, user_id])
    |> Enum.map(fn [id] -> id end)
  end

  defp do_search(conn, term, opts) do
    limit = Keyword.get(opts, :limit, 50)
    {where_clauses, params} = build_fts_filters(opts)

    base_sql = """
    SELECT e.event_json, e.app_name, e.user_id, e.session_id
    FROM events_fts fts
    JOIN events e ON e.id = fts.rowid
    WHERE events_fts MATCH ?1
    """

    sql = base_sql <> where_clauses <> " ORDER BY fts.rank LIMIT ?#{length(params) + 2}"
    all_params = [term] ++ params ++ [limit]

    query_all(conn, sql, all_params)
    |> Enum.map(fn [json, app, user, sess] ->
      event = Jason.decode!(json, keys: :atoms)
      Map.merge(event, %{app_name: app, user_id: user, session_id: sess})
    end)
  end

  defp do_search_sessions(conn, term, opts) do
    {where_clauses, params} = build_fts_filters(opts)

    sql =
      """
      SELECT DISTINCT e.session_id
      FROM events_fts fts
      JOIN events e ON e.id = fts.rowid
      WHERE events_fts MATCH ?1
      """ <> where_clauses

    all_params = [term] ++ params

    query_all(conn, sql, all_params)
    |> Enum.map(fn [id] -> id end)
  end

  defp build_fts_filters(opts) do
    filters =
      [
        {:app_name, Keyword.get(opts, :app_name)},
        {:user_id, Keyword.get(opts, :user_id)},
        {:session_id, Keyword.get(opts, :session_id)}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    {clauses, params, _idx} =
      Enum.reduce(filters, {[], [], 2}, fn {field, value}, {cls, prms, idx} ->
        clause = " AND e.#{field} = ?#{idx}"
        {cls ++ [clause], prms ++ [value], idx + 1}
      end)

    {Enum.join(clauses), params}
  end

  # --- Serialization ---

  defp serialize_event(%ADK.Event{} = event) do
    content_text = extract_text(event.content)

    event_map = %{
      id: event.id,
      invocation_id: event.invocation_id,
      author: event.author,
      branch: event.branch,
      timestamp: event.timestamp && DateTime.to_iso8601(event.timestamp),
      content: event.content,
      partial: event.partial,
      actions: serialize_actions(event.actions),
      error: event.error
    }

    {event.id, event.author, content_text, Jason.encode!(event_map)}
  end

  defp serialize_event(event) when is_map(event) do
    content_text = extract_text(Map.get(event, :content))
    {Map.get(event, :id), Map.get(event, :author), content_text, Jason.encode!(event)}
  end

  defp extract_text(nil), do: nil

  defp extract_text(%{parts: parts}) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{text: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_text(_), do: nil

  defp serialize_actions(%ADK.EventActions{} = actions) do
    %{
      state_delta: actions.state_delta,
      transfer_to_agent: actions.transfer_to_agent,
      escalate: actions.escalate
    }
  end

  defp serialize_actions(other), do: other

  # --- SQLite Helpers ---

  defp execute(conn, sql, params \\ []) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- bind_params(conn, stmt, params),
         :done <- Exqlite.Sqlite3.step(conn, stmt),
         :ok <- Exqlite.Sqlite3.release(conn, stmt) do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      # step can return :row for PRAGMA etc — that's fine
      {:row, _} ->
        :ok
    end
  end

  defp query_one(conn, sql, params) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- bind_params(conn, stmt, params) do
      result =
        case Exqlite.Sqlite3.step(conn, stmt) do
          {:row, row} -> {:ok, row}
          :done -> nil
        end

      Exqlite.Sqlite3.release(conn, stmt)
      result
    end
  end

  defp query_all(conn, sql, params) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- bind_params(conn, stmt, params) do
      rows = fetch_rows(conn, stmt, [])
      Exqlite.Sqlite3.release(conn, stmt)
      rows
    else
      _ -> []
    end
  end

  defp fetch_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_rows(conn, stmt, acc ++ [row])
      :done -> acc
    end
  end

  defp bind_params(_conn, _stmt, []), do: :ok

  defp bind_params(_conn, stmt, params) do
    Exqlite.Sqlite3.bind(stmt, params)
  end
end
