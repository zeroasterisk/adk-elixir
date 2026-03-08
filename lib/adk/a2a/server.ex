defmodule ADK.A2A.Server do
  @moduledoc """
  A2A protocol server implemented as a Plug.

  Serves the Agent Card at `GET /.well-known/agent.json` and handles
  JSON-RPC 2.0 requests at `POST /`.

  ## Usage

      # In a Plug router or endpoint:
      plug ADK.A2A.Server,
        agent: my_agent_spec,
        runner: %ADK.Runner{app_name: "my_app", agent: my_agent_spec},
        url: "http://localhost:4000/a2a"

  Tasks are stored in an ETS table for simplicity.
  """

  @behaviour Plug

  alias ADK.A2A.{AgentCard, Message}

  @impl true
  @spec init(keyword()) :: map()
  def init(opts) do
    table = :ets.new(:a2a_tasks, [:set, :public])

    %{
      agent: Keyword.fetch!(opts, :agent),
      runner: Keyword.fetch!(opts, :runner),
      url: Keyword.get(opts, :url, "http://localhost:4000"),
      card_opts: Keyword.get(opts, :card_opts, []),
      table: table
    }
  end

  @impl true
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "GET", path_info: [".well-known", "agent.json"]} = conn, config) do
    card_opts = Keyword.merge(config.card_opts, url: config.url)
    card = AgentCard.from_agent(config.agent, card_opts)
    json_response(conn, 200, card)
  end

  def call(%Plug.Conn{method: "POST", path_info: []} = conn, config) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case Jason.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}} ->
        handle_rpc(conn, config, id, method, params)

      {:ok, %{"jsonrpc" => "2.0", "id" => id, "method" => method}} ->
        handle_rpc(conn, config, id, method, %{})

      {:ok, _} ->
        json_rpc_error(conn, nil, -32600, "Invalid Request")

      {:error, _} ->
        json_rpc_error(conn, nil, -32700, "Parse error")
    end
  end

  def call(conn, _config) do
    json_response(conn, 404, %{"error" => "not found"})
  end

  # -- JSON-RPC handlers --

  defp handle_rpc(conn, config, id, "tasks/send", params) do
    task_id = generate_task_id()
    message_text = extract_message_text(params)
    user_id = params["sessionId"] || "a2a-user"
    session_id = params["sessionId"] || "a2a-#{task_id}"

    # Store initial task
    task = %{
      "id" => task_id,
      "status" => %{"state" => "working"},
      "history" => [],
      "artifacts" => []
    }

    :ets.insert(config.table, {task_id, task})

    # Run the agent
    try do
      events = ADK.Runner.run(config.runner, user_id, session_id, message_text)

      # Convert events to A2A messages
      messages = Enum.map(events, &Message.from_event/1)

      # Build artifacts from agent messages
      artifacts =
        messages
        |> Enum.filter(fn m -> m["role"] == "agent" end)
        |> Enum.map(fn m -> %{"parts" => m["parts"]} end)

      completed_task = %{
        "id" => task_id,
        "status" => %{"state" => "completed"},
        "history" => messages,
        "artifacts" => artifacts
      }

      :ets.insert(config.table, {task_id, completed_task})
      json_rpc_result(conn, id, completed_task)
    rescue
      e ->
        failed_task = %{
          "id" => task_id,
          "status" => %{
            "state" => "failed",
            "message" => %{
              "role" => "agent",
              "parts" => [%{"type" => "text", "text" => Exception.message(e)}]
            }
          },
          "history" => [],
          "artifacts" => []
        }

        :ets.insert(config.table, {task_id, failed_task})
        json_rpc_result(conn, id, failed_task)
    end
  end

  defp handle_rpc(conn, config, id, "tasks/get", %{"id" => task_id}) do
    case :ets.lookup(config.table, task_id) do
      [{^task_id, task}] -> json_rpc_result(conn, id, task)
      [] -> json_rpc_error(conn, id, -32001, "Task not found")
    end
  end

  defp handle_rpc(conn, config, id, "tasks/cancel", %{"id" => task_id}) do
    case :ets.lookup(config.table, task_id) do
      [{^task_id, task}] ->
        canceled = put_in(task, ["status", "state"], "canceled")
        :ets.insert(config.table, {task_id, canceled})
        json_rpc_result(conn, id, canceled)

      [] ->
        json_rpc_error(conn, id, -32001, "Task not found")
    end
  end

  defp handle_rpc(conn, _config, id, method, _params) do
    json_rpc_error(conn, id, -32601, "Method not found: #{method}")
  end

  # -- Helpers --

  defp extract_message_text(%{"message" => %{"parts" => parts}}) do
    Enum.find_value(parts, "hello", fn
      %{"type" => "text", "text" => t} -> t
      %{"text" => t} -> t
      _ -> nil
    end)
  end

  defp extract_message_text(%{"message" => msg}) when is_binary(msg), do: msg
  defp extract_message_text(_), do: "hello"

  defp json_rpc_result(conn, id, result) do
    json_response(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp json_rpc_error(conn, id, code, message) do
    json_response(conn, 200, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp generate_task_id do
    "task-" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end
