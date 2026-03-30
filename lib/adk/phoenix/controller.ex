defmodule ADK.Phoenix.Controller do
  @moduledoc """
  Helper functions for building Phoenix controllers that interact with ADK agents.

  These are plain functions — no `use` macro, no Phoenix dependency at compile time.
  They expect a `Plug.Conn` and work with any Phoenix controller.

  ## Usage

      defmodule MyAppWeb.AgentController do
        use MyAppWeb, :controller

        def run(conn, params) do
          runner = %ADK.Runner{app_name: "my_app", agent: MyApp.agent()}
          ADK.Phoenix.Controller.run(conn, runner, params)
        end

        def stream(conn, params) do
          runner = %ADK.Runner{app_name: "my_app", agent: MyApp.agent()}
          ADK.Phoenix.Controller.stream_sse(conn, runner, params)
        end
      end
  """

  @doc """
  Run an agent synchronously and return JSON events.

  Expects `params` to contain `"message"`, and optionally `"user_id"` and `"session_id"`.
  Returns a JSON response with `%{events: [...]}`.
  """
  @spec run(Plug.Conn.t(), ADK.Runner.t(), map(), keyword()) :: Plug.Conn.t()
  def run(conn, %ADK.Runner{} = runner, params, opts \\ []) do
    user_id = params["user_id"] || opts[:user_id] || "anonymous"
    session_id = params["session_id"] || opts[:session_id] || "default"
    message = params["message"] || ""

    events = ADK.Runner.run(runner, user_id, session_id, message)
    event_maps = Enum.map(events, &ADK.Event.to_map/1)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{events: event_maps}))
  end

  @doc """
  Run an agent and stream events as Server-Sent Events (SSE).

  Each event is sent as an SSE `data:` line with JSON payload.
  The stream ends with a `data: [DONE]` sentinel.
  """
  @spec stream_sse(Plug.Conn.t(), ADK.Runner.t(), map(), keyword()) :: Plug.Conn.t()
  def stream_sse(conn, %ADK.Runner{} = runner, params, opts \\ []) do
    user_id = params["user_id"] || opts[:user_id] || "anonymous"
    session_id = params["session_id"] || opts[:session_id] || "default"
    message = params["message"] || ""

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    events = ADK.Runner.run(runner, user_id, session_id, message)

    Enum.each(events, fn event ->
      chunk = "data: #{Jason.encode!(ADK.Event.to_map(event))}\n\n"
      chunk(conn, chunk)
    end)

    chunk(conn, "data: [DONE]\n\n")
    conn
  end

  defp plug_conn do
    # Runtime lookup to avoid compile-time dependency on Plug
    case Code.ensure_loaded(Plug.Conn) do
      {:module, mod} ->
        mod

      _ ->
        raise "Plug.Conn is required for ADK.Phoenix.Controller. Add :plug to your dependencies."
    end
  end

  defp put_resp_content_type(conn, type), do: plug_conn().put_resp_content_type(conn, type)
  defp send_resp(conn, status, body), do: plug_conn().send_resp(conn, status, body)
  defp send_chunked(conn, status), do: plug_conn().send_chunked(conn, status)
  defp chunk(conn, data), do: plug_conn().chunk(conn, data)
end
