defmodule ADK.Phoenix.WebRouterTest do
  use ExUnit.Case, async: false

  @moduletag :web_router

  defp echo_agent do
    ADK.Agent.Custom.new(
      name: "echo",
      description: "Echo agent",
      run_fn: fn _agent, ctx ->
        text =
          case ctx.user_content do
            %{text: t} -> t
            t when is_binary(t) -> t
            _ -> "echo"
          end

        [
          ADK.Event.new(%{
            author: "echo",
            content: %{role: :model, parts: [%{text: "Echo: #{text}"}]}
          })
        ]
      end
    )
  end

  defp build_conn(method, path, body \\ nil) do
    conn = Plug.Test.conn(method, path, body && Jason.encode!(body))

    if body do
      conn |> Plug.Conn.put_req_header("content-type", "application/json")
    else
      conn
    end
  end

  defp call(conn) do
    agents = %{"test_app" => echo_agent()}

    opts = [
      agent_loader: agents,
      session_store: {ADK.Session.Store.InMemory, []}
    ]

    ADK.Phoenix.WebRouter.call(conn, ADK.Phoenix.WebRouter.init(opts))
  end

  describe "GET /health" do
    test "returns healthy status" do
      conn = build_conn(:get, "/health") |> call()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"status" => "healthy"}
    end
  end

  describe "GET /version" do
    test "returns version" do
      conn = build_conn(:get, "/version") |> call()
      assert conn.status == 200
      assert %{"version" => _} = Jason.decode!(conn.resp_body)
    end
  end

  describe "GET /list-apps" do
    test "returns list of app names" do
      conn = build_conn(:get, "/list-apps") |> call()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == ["test_app"]
    end

    test "returns detailed info with ?detailed=true" do
      conn = build_conn(:get, "/list-apps?detailed=true") |> call()
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert %{"apps" => [%{"name" => "test_app"}]} = body
    end
  end

  describe "session CRUD" do
    test "create, get, list, delete session" do
      # Create
      conn =
        build_conn(:post, "/apps/test_app/users/user1/sessions", %{
          session_id: "sess-crud-test",
          state: %{"key" => "value"}
        })
        |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == "sess-crud-test"
      assert body["app_name"] == "test_app"
      assert body["user_id"] == "user1"
      assert body["state"] == %{"key" => "value"}

      # Get
      conn = build_conn(:get, "/apps/test_app/users/user1/sessions/sess-crud-test") |> call()
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == "sess-crud-test"

      # List
      conn = build_conn(:get, "/apps/test_app/users/user1/sessions") |> call()
      assert conn.status == 200
      sessions = Jason.decode!(conn.resp_body)
      assert Enum.any?(sessions, fn s -> s["id"] == "sess-crud-test" end)

      # Delete
      conn = build_conn(:delete, "/apps/test_app/users/user1/sessions/sess-crud-test") |> call()
      assert conn.status == 200

      # Verify deleted
      conn = build_conn(:get, "/apps/test_app/users/user1/sessions/sess-crud-test") |> call()
      assert conn.status == 404
    end

    test "create session with auto-generated id" do
      conn =
        build_conn(:post, "/apps/test_app/users/user1/sessions", %{})
        |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["id"])
      assert String.length(body["id"]) > 0

      # Cleanup
      build_conn(:delete, "/apps/test_app/users/user1/sessions/#{body["id"]}") |> call()
    end

    test "get non-existent session returns 404" do
      conn = build_conn(:get, "/apps/test_app/users/user1/sessions/nonexistent") |> call()
      assert conn.status == 404
    end
  end

  describe "POST /run" do
    test "runs agent and returns events" do
      # Create session first
      build_conn(:post, "/apps/test_app/users/user1/sessions", %{
        session_id: "run-test"
      })
      |> call()

      conn =
        build_conn(:post, "/run", %{
          app_name: "test_app",
          user_id: "user1",
          session_id: "run-test",
          new_message: %{parts: [%{text: "hello"}]}
        })
        |> call()

      assert conn.status == 200
      events = Jason.decode!(conn.resp_body)
      assert is_list(events)

      # Cleanup
      build_conn(:delete, "/apps/test_app/users/user1/sessions/run-test") |> call()
    end

    test "returns 404 for unknown app" do
      conn =
        build_conn(:post, "/run", %{
          app_name: "nonexistent",
          user_id: "user1",
          session_id: "s1",
          new_message: %{parts: [%{text: "hi"}]}
        })
        |> call()

      assert conn.status == 404
    end
  end

  describe "POST /run_sse" do
    test "streams events as SSE" do
      # Create session first
      build_conn(:post, "/apps/test_app/users/user1/sessions", %{
        session_id: "sse-test"
      })
      |> call()

      conn =
        build_conn(:post, "/run_sse", %{
          app_name: "test_app",
          user_id: "user1",
          session_id: "sse-test",
          new_message: %{parts: [%{text: "hello"}]},
          streaming: false
        })
        |> call()

      assert conn.status == 200

      assert {"content-type", content_type} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert content_type =~ "text/event-stream"

      # Cleanup
      build_conn(:delete, "/apps/test_app/users/user1/sessions/sse-test") |> call()
    end

    test "returns 404 for unknown app" do
      conn =
        build_conn(:post, "/run_sse", %{
          app_name: "nonexistent",
          user_id: "user1",
          session_id: "s1",
          new_message: %{parts: [%{text: "hi"}]}
        })
        |> call()

      assert conn.status == 404
    end
  end

  describe "CORS" do
    test "OPTIONS returns CORS headers" do
      conn = build_conn(:options, "/list-apps") |> call()
      assert conn.status == 204
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "responses include CORS headers" do
      conn = build_conn(:get, "/health") |> call()
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end
end
