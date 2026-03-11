defmodule ADK.Phoenix.WebRouter do
  @moduledoc """
  Plug router providing Python ADK-compatible HTTP endpoints.

  This module implements the same REST API as Python ADK's `adk web` FastAPI server,
  enabling the adk-web React frontend to work with an Elixir backend as a drop-in
  replacement.

  ## Endpoints

    * `GET /list-apps` — List available agent apps
    * `GET /apps/:app_name/users/:user_id/sessions` — List sessions
    * `POST /apps/:app_name/users/:user_id/sessions` — Create session
    * `GET /apps/:app_name/users/:user_id/sessions/:session_id` — Get session
    * `DELETE /apps/:app_name/users/:user_id/sessions/:session_id` — Delete session
    * `POST /run_sse` — Run agent with SSE streaming response
    * `POST /run` — Run agent synchronously
    * `GET /health` — Health check
    * `GET /version` — Version info
    * `GET /debug/trace/:event_id` — Get span attributes for a specific event
    * `GET /debug/trace/session/:session_id` — Get all spans for a session

  ## Usage

  Add to your Phoenix router or use standalone:

      # In a Phoenix router
      forward "/", ADK.Phoenix.WebRouter,
        agent_loader: MyApp.AgentLoader,
        session_store: {ADK.Session.Store.InMemory, []}

      # Standalone with Bandit/Cowboy
      Bandit.start_link(plug: {ADK.Phoenix.WebRouter, opts})

  ## Options

    * `:agent_loader` — Module implementing `list_agents/0` and `load_agent/1` callbacks,
      or a map of `%{app_name => agent}` for simple cases.
    * `:session_store` — `{module, opts}` tuple for session persistence.
      Defaults to `{ADK.Session.Store.InMemory, []}`.
    * `:allow_origins` — List of allowed CORS origins. Defaults to `["*"]`.
  """

  use Plug.Router

  plug Plug.Logger, log: :debug
  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :put_cors_headers
  plug :dispatch

  # --- Routes ---

  get "/health" do
    json(conn, 200, %{status: "healthy"})
  end

  get "/version" do
    json(conn, 200, %{version: "0.1.0"})
  end

  get "/list-apps" do
    loader = get_agent_loader(conn)
    apps = list_agents(loader)

    case conn.query_params["detailed"] do
      "true" ->
        detailed = list_agents_detailed(loader)
        json(conn, 200, %{apps: detailed})

      _ ->
        json(conn, 200, apps)
    end
  end

  get "/apps/:app_name/users/:user_id/sessions/:session_id" do
    store = get_store(conn)

    case store_mod(store).load(app_name, user_id, session_id) do
      {:ok, data} ->
        json(conn, 200, session_to_python_format(data, app_name, user_id, session_id))

      {:error, :not_found} ->
        # Try from live session
        case ADK.Session.lookup(app_name, user_id, session_id) do
          {:ok, pid} ->
            {:ok, session} = ADK.Session.get(pid)
            json(conn, 200, session_to_python_format(session))

          :error ->
            json(conn, 404, %{detail: "Session not found"})
        end
    end
  end

  get "/apps/:app_name/users/:user_id/sessions" do
    store = get_store(conn)
    session_ids = store_mod(store).list(app_name, user_id)

    sessions =
      Enum.map(session_ids, fn sid ->
        case store_mod(store).load(app_name, user_id, sid) do
          {:ok, data} -> session_to_python_format(data, app_name, user_id, sid)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Also include live sessions not yet persisted
    live_sessions = get_live_sessions(app_name, user_id, session_ids)
    json(conn, 200, sessions ++ live_sessions)
  end

  post "/apps/:app_name/users/:user_id/sessions" do
    store = get_store(conn)
    req_body = conn.body_params || %{}

    session_id = req_body["session_id"] || generate_id()
    initial_state = req_body["state"] || %{}

    # Check if session already exists
    case store_mod(store).load(app_name, user_id, session_id) do
      {:ok, _} ->
        json(conn, 409, %{detail: "Session already exists: #{session_id}"})

      {:error, :not_found} ->
        # Create session process
        session_opts = [
          app_name: app_name,
          user_id: user_id,
          session_id: session_id,
          initial_state: initial_state,
          store: store,
          auto_save: true
        ]

        case ADK.Session.start_supervised(session_opts) do
          {:ok, pid} ->
            # Save immediately to store
            ADK.Session.save(pid)

            {:ok, session} = ADK.Session.get(pid)
            json(conn, 200, session_to_python_format(session))

          {:error, {:already_started, pid}} ->
            {:ok, session} = ADK.Session.get(pid)
            json(conn, 200, session_to_python_format(session))

          {:error, reason} ->
            json(conn, 500, %{detail: inspect(reason)})
        end
    end
  end

  delete "/apps/:app_name/users/:user_id/sessions/:session_id" do
    store = get_store(conn)

    # Stop live session first (it may auto_save on terminate, so we delete from store after)
    case ADK.Session.lookup(app_name, user_id, session_id) do
      {:ok, pid} -> GenServer.stop(pid, :normal)
      :error -> :ok
    end

    # Delete from store after stopping process to avoid auto_save race
    store_mod(store).delete(app_name, user_id, session_id)

    send_resp(conn, 200, "")
  end

  post "/run" do
    req = conn.body_params
    loader = get_agent_loader(conn)
    store = get_store(conn)

    with {:ok, agent} <- load_agent(loader, req["app_name"]) do
      runner =
        ADK.Runner.new(
          app_name: req["app_name"],
          agent: agent,
          session_store: store
        )

      message = extract_message(req["new_message"])

      events =
        ADK.Runner.run(
          runner,
          req["user_id"],
          req["session_id"],
          message,
          stop_session: false
        )

      event_maps = Enum.map(events, &event_to_python_format/1)
      json(conn, 200, event_maps)
    else
      {:error, :not_found} ->
        json(conn, 404, %{detail: "App not found: #{req["app_name"]}"})
    end
  end

  post "/run_sse" do
    req = conn.body_params
    loader = get_agent_loader(conn)
    store = get_store(conn)

    with {:ok, _agent} <- load_agent(loader, req["app_name"]) do
      # Validate session exists if not auto-creating
      case validate_session(store, req["app_name"], req["user_id"], req["session_id"]) do
        :ok ->
          stream_agent_sse(conn, loader, store, req)

        {:error, :not_found} ->
          # Auto-create and stream
          stream_agent_sse(conn, loader, store, req)
      end
    else
      {:error, :not_found} ->
        json(conn, 404, %{detail: "App not found: #{req["app_name"]}"})
    end
  end

  # --- Debug/Trace Endpoints ---

  get "/debug/trace/session/:session_id" do
    spans = ADK.Telemetry.SpanStore.get_session_spans(session_id)
    json(conn, 200, spans)
  end

  get "/debug/trace/:event_id" do
    case ADK.Telemetry.SpanStore.get_event_span(event_id) do
      {:ok, attrs} -> json(conn, 200, attrs)
      :not_found -> json(conn, 404, %{detail: "Trace not found"})
    end
  end

  # CORS preflight
  options _ do
    conn
    |> send_resp(204, "")
  end

  match _ do
    json(conn, 404, %{detail: "Not found"})
  end

  # --- Private Helpers ---

  defp stream_agent_sse(conn, loader, store, req) do
    {:ok, agent} = load_agent(loader, req["app_name"])

    runner =
      ADK.Runner.new(
        app_name: req["app_name"],
        agent: agent,
        session_store: store
      )

    message = extract_message(req["new_message"])

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Thread conn state through the on_event lambda so chunks accumulate
    # correctly in both real HTTP adapters (socket writes) and Plug.Test
    # (resp_body accumulation via returned conn).
    {:ok, conn_ref} = Agent.start_link(fn -> conn end)

    try do
      ADK.Runner.run_streaming(
        runner,
        req["user_id"],
        req["session_id"],
        message,
        stop_session: false,
        on_event: fn event ->
          current_conn = Agent.get(conn_ref, & &1)
          sse_data = Jason.encode!(event_to_python_format(event))
          case chunk(current_conn, "data: #{sse_data}\n\n") do
            {:ok, updated_conn} -> Agent.update(conn_ref, fn _ -> updated_conn end)
            _ -> :ok
          end
        end
      )
    rescue
      e ->
        current_conn = Agent.get(conn_ref, & &1)
        error_json = Jason.encode!(%{error: Exception.message(e)})
        case chunk(current_conn, "data: #{error_json}\n\n") do
          {:ok, updated_conn} -> Agent.update(conn_ref, fn _ -> updated_conn end)
          _ -> :ok
        end
    end

    final_conn = Agent.get(conn_ref, & &1)
    Agent.stop(conn_ref)
    final_conn
  end

  defp extract_message(nil), do: ""

  defp extract_message(%{"parts" => parts}) when is_list(parts) do
    # Extract text from Content format matching Python's types.Content
    Enum.find_value(parts, "", fn
      %{"text" => t} -> t
      _ -> nil
    end)
  end

  defp extract_message(%{"text" => text}), do: text
  defp extract_message(msg) when is_binary(msg), do: msg
  defp extract_message(_), do: ""

  defp validate_session(store, app_name, user_id, session_id) do
    case store_mod(store).load(app_name, user_id, session_id) do
      {:ok, _} -> :ok
      {:error, :not_found} ->
        case ADK.Session.lookup(app_name, user_id, session_id) do
          {:ok, _} -> :ok
          :error -> {:error, :not_found}
        end
    end
  end

  defp event_to_python_format(%ADK.Event{} = event) do
    map = %{
      id: event.id,
      invocation_id: event.invocation_id,
      author: event.author,
      timestamp: event.timestamp && DateTime.to_unix(event.timestamp, :microsecond) / 1_000_000,
      content: event.content,
      partial: event.partial,
      actions: actions_to_python_format(event.actions)
    }

    map
    |> maybe_put(:branch, event.branch)
    |> maybe_put(:error, event.error)
    |> drop_nils()
  end

  defp event_to_python_format(map) when is_map(map), do: map

  defp actions_to_python_format(%ADK.EventActions{} = actions) do
    %{
      state_delta: actions.state_delta,
      transfer_to_agent: actions.transfer_to_agent,
      escalate: actions.escalate,
      artifact_delta: %{}
    }
    |> drop_nils()
  end

  defp actions_to_python_format(_), do: %{}

  defp session_to_python_format(%ADK.Session{} = session) do
    %{
      id: session.id,
      app_name: session.app_name,
      user_id: session.user_id,
      state: session.state || %{},
      events: Enum.map(session.events, &event_to_python_format/1),
      last_update_time: 0.0
    }
  end

  defp session_to_python_format(data, app_name, user_id, session_id) when is_map(data) do
    %{
      id: data[:id] || data["id"] || session_id,
      app_name: data[:app_name] || data["app_name"] || app_name,
      user_id: data[:user_id] || data["user_id"] || user_id,
      state: data[:state] || data["state"] || %{},
      events: (data[:events] || data["events"] || []) |> Enum.map(&event_to_python_format/1),
      last_update_time: 0.0
    }
  end

  defp get_live_sessions(app_name, user_id, exclude_ids) do
    # Look up live sessions from the registry
    Registry.select(ADK.SessionRegistry, [
      {{{app_name, user_id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.reject(fn {sid, _pid} -> sid in exclude_ids end)
    |> Enum.map(fn {_sid, pid} ->
      {:ok, session} = ADK.Session.get(pid)
      session_to_python_format(session)
    end)
  end

  defp get_agent_loader(conn), do: conn.private[:adk_agent_loader]
  defp get_store(conn), do: conn.private[:adk_session_store] || {ADK.Session.Store.InMemory, []}

  defp store_mod({mod, _opts}), do: mod
  defp store_mod(nil), do: ADK.Session.Store.InMemory

  defp list_agents(loader) when is_map(loader), do: Map.keys(loader)

  defp list_agents(loader) when is_atom(loader) do
    if function_exported?(loader, :list_agents, 0) do
      loader.list_agents()
    else
      []
    end
  end

  defp list_agents(_), do: []

  defp list_agents_detailed(loader) when is_map(loader) do
    Enum.map(loader, fn {name, agent} ->
      %{
        name: name,
        root_agent_name: ADK.Agent.name(agent),
        description: Map.get(agent, :description, ""),
        language: "elixir",
        is_computer_use: false
      }
    end)
  end

  defp list_agents_detailed(loader) when is_atom(loader) do
    if function_exported?(loader, :list_agents_detailed, 0) do
      loader.list_agents_detailed()
    else
      list_agents(loader)
      |> Enum.map(fn name -> %{name: name, root_agent_name: name, description: "", language: "elixir", is_computer_use: false} end)
    end
  end

  defp list_agents_detailed(_), do: []

  defp load_agent(loader, app_name) when is_map(loader) do
    case Map.fetch(loader, app_name) do
      {:ok, agent} -> {:ok, agent}
      :error -> {:error, :not_found}
    end
  end

  defp load_agent(loader, app_name) when is_atom(loader) do
    if function_exported?(loader, :load_agent, 1) do
      case loader.load_agent(app_name) do
        nil -> {:error, :not_found}
        agent -> {:ok, agent}
      end
    else
      {:error, :not_found}
    end
  end

  defp load_agent(_, _), do: {:error, :not_found}

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp put_cors_headers(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nils(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  # --- Plug Init/Call ---

  @doc """
  Initialize the router with options.

  ## Options

    * `:agent_loader` — Map of `%{app_name => agent}` or module with `list_agents/0` and `load_agent/1`
    * `:session_store` — `{module, opts}` tuple
    * `:allow_origins` — CORS origins list
  """
  def init(opts), do: opts

  def call(conn, opts) do
    conn =
      conn
      |> put_private(:adk_agent_loader, opts[:agent_loader])
      |> put_private(:adk_session_store, opts[:session_store])
      |> put_private(:adk_allow_origins, opts[:allow_origins] || ["*"])

    super(conn, opts)
  end
end
