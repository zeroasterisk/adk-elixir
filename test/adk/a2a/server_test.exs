defmodule ADK.A2A.ServerTest do
  use ExUnit.Case, async: true

  alias ADK.A2A.Server

  # Concurrency guarantee: ADK.A2A.Server.Bridge processes ALL calls
  # (message/send AND tasks/cancel) through the same GenServer, so they
  # are serialized.  A task stored during handle_call({:message, …}) is
  # guaranteed to be visible to a subsequent handle_call({:cancel, …})
  # with no extra synchronization needed.  Tests are still `async: true`
  # safe because each setup creates uniquely-named ETS tables and a
  # uniquely-named Bridge GenServer, so concurrent test cases never
  # share state.

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

    # Warm up: verify the Bridge GenServer is fully started and responsive
    # before running any test.  This prevents a false-flaky failure on cold
    # BEAM starts where the GenServer may be scheduled but not yet processing.
    bridge_name = :"adk_a2a_bridge_adk_a2a_config_#{uid}"
    :ok = wait_for_bridge(bridge_name)

    %{config: config}
  end

  # Poll until the named GenServer is alive and responding, up to 1 second.
  defp wait_for_bridge(name, attempts \\ 20) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) ->
        # Ping with a lightweight call to confirm it's processing messages
        try do
          GenServer.call(pid, :get_agent_card, 1_000)
          :ok
        catch
          :exit, _ -> retry_wait_for_bridge(name, attempts)
        end

      nil ->
        retry_wait_for_bridge(name, attempts)
    end
  end

  defp retry_wait_for_bridge(_name, 0), do: :ok
  defp retry_wait_for_bridge(name, n) do
    Process.sleep(50)
    wait_for_bridge(name, n - 1)
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
    # The Bridge processes agent logic synchronously inside the GenServer call,
    # so the task is guaranteed to be COMPLETED in state before this returns.
    send_conn = send_message(config)
    send_resp = Jason.decode!(send_conn.resp_body)

    # Explicitly verify the task is completed before attempting cancel.
    # If this assertion fails, the cancel test below would be misleading —
    # a working/submitted task CAN be canceled, so we'd get a false pass.
    task = send_resp["result"]["task"]
    assert task["status"]["state"] == "TASK_STATE_COMPLETED",
           "Expected task to be TASK_STATE_COMPLETED before cancel, got: #{task["status"]["state"]}"

    task_id = task["id"]

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
    # Completed tasks can't be canceled — expect a task_not_cancelable error
    assert resp["error"] != nil,
           "Expected cancel of COMPLETED task to return an error, got result: #{inspect(resp["result"])}"
    assert resp["result"] == nil
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
