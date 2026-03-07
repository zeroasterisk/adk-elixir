defmodule ADK.A2A.ServerTest do
  use ExUnit.Case, async: true

  alias ADK.A2A.Server

  # A simple mock agent module that returns a canned response
  defmodule MockAgent do
    def run(_ctx) do
      [
        ADK.Event.new(%{
          author: "test_agent",
          content: %{parts: [%{text: "Hello from agent"}]}
        })
      ]
    end
  end

  setup do
    agent = %ADK.Agent{
      name: "test_agent",
      description: "A test agent",
      module: MockAgent,
      config: %{tools: []},
      sub_agents: []
    }

    runner = %ADK.Runner{app_name: "test", agent: agent}

    config = Server.init(agent: agent, runner: runner, url: "http://localhost:4000")
    %{config: config}
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

  test "POST / with tasks/send returns completed task", %{config: config} do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks/send",
        "params" => %{
          "message" => %{
            "role" => "user",
            "parts" => [%{"type" => "text", "text" => "hi"}]
          }
        }
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Server.call(config)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["jsonrpc"] == "2.0"
    assert resp["id"] == "1"
    result = resp["result"]
    assert result["status"]["state"] == "completed"
    assert is_list(result["artifacts"])
    assert is_binary(result["id"])
  end

  test "POST / with tasks/get returns task", %{config: config} do
    # First send a task
    send_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks/send",
        "params" => %{
          "message" => %{
            "role" => "user",
            "parts" => [%{"type" => "text", "text" => "hi"}]
          }
        }
      })

    send_conn =
      Plug.Test.conn(:post, "/", send_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Server.call(config)

    task_id = Jason.decode!(send_conn.resp_body)["result"]["id"]

    # Now get it
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
    assert resp["result"]["id"] == task_id
    assert resp["result"]["status"]["state"] == "completed"
  end

  test "POST / with tasks/cancel cancels a task", %{config: config} do
    # Send a task first
    send_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks/send",
        "params" => %{
          "message" => %{
            "role" => "user",
            "parts" => [%{"type" => "text", "text" => "hi"}]
          }
        }
      })

    send_conn =
      Plug.Test.conn(:post, "/", send_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Server.call(config)

    task_id = Jason.decode!(send_conn.resp_body)["result"]["id"]

    # Cancel it
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
    assert resp["result"]["status"]["state"] == "canceled"
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
