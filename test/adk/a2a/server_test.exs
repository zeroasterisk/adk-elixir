defmodule ADK.A2A.ServerTest do
  use ExUnit.Case, async: true

  alias ADK.A2A.Server

  setup do
    agent = ADK.Agent.Custom.new(
      name: "test_agent",
      description: "A test agent",
      run_fn: fn _agent, _ctx ->
        [
          ADK.Event.new(%{
            author: "test_agent",
            content: %{parts: [%{text: "Hello from agent"}]}
          })
        ]
      end
    )

    runner = %ADK.Runner{app_name: "test", agent: agent}

    uid = System.unique_integer([:positive])
    config = Server.init(
      agent: agent,
      runner: runner,
      url: "http://localhost:4000",
      config_table_name: :"adk_a2a_config_#{uid}",
      task_table_name: :"adk_a2a_tasks_#{uid}"
    )
    %{config: config}
  end

  defp send_message(config, text \\ "hi") do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message/send",
        "params" => %{
          "message" => %{
            "messageId" => "msg-#{System.unique_integer([:positive])}",
            "role" => "user",
            "parts" => [%{"type" => "text", "text" => text}]
          }
        }
      })

    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Server.call(config)
  end

  test "GET /.well-known/agent.json returns agent card", %{config: config} do
    conn =
      Plug.Test.conn(:get, "/.well-known/agent.json")
      |> Server.call(config)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "test_agent"
    assert body["url"] == "http://localhost:4000"
  end

  test "POST / with message/send returns completed task", %{config: config} do
    conn = send_message(config)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["jsonrpc"] == "2.0"
    assert resp["id"] == "1"
    task = resp["result"]["task"]
    assert task["status"]["state"] == "TASK_STATE_COMPLETED"
    assert is_list(task["artifacts"])
    assert is_binary(task["id"])
  end

  test "POST / with tasks/get returns task", %{config: config} do
    send_conn = send_message(config)
    task_id = Jason.decode!(send_conn.resp_body)["result"]["task"]["id"]

    get_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "2",
        "method" => "tasks/get",
        "params" => %{"id" => task_id}
      })

    get_conn =
      Plug.Test.conn(:post, "/", get_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Server.call(config)

    resp = Jason.decode!(get_conn.resp_body)
    # tasks/get returns the task directly as result (not wrapped in "task" key)
    result = resp["result"]
    task = result["task"] || result
    assert task["id"] == task_id
    assert task["status"]["state"] == "TASK_STATE_COMPLETED"
  end

  test "POST / with tasks/cancel on completed task returns error", %{config: config} do
    send_conn = send_message(config)
    task_id = Jason.decode!(send_conn.resp_body)["result"]["task"]["id"]

    cancel_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "2",
        "method" => "tasks/cancel",
        "params" => %{"id" => task_id}
      })

    cancel_conn =
      Plug.Test.conn(:post, "/", cancel_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Server.call(config)

    resp = Jason.decode!(cancel_conn.resp_body)
    # Completed tasks can't be canceled — expect an error
    assert resp["error"] != nil
  end

  test "POST / with unknown method returns error", %{config: config} do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "unknown/method",
        "params" => %{}
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Server.call(config)

    resp = Jason.decode!(conn.resp_body)
    assert resp["error"]["code"] == -32601
  end

  test "POST / with invalid JSON returns parse error", %{config: config} do
    conn =
      Plug.Test.conn(:post, "/", "not json")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Server.call(config)

    resp = Jason.decode!(conn.resp_body)
    assert resp["error"]["code"] == -32700
  end

  test "GET /unknown returns 404", %{config: config} do
    conn = Plug.Test.conn(:get, "/something") |> Server.call(config)
    assert conn.status == 404
  end
end
