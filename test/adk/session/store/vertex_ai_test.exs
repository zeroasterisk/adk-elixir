defmodule ADK.Session.Store.VertexAITest do
  use ExUnit.Case, async: false

  alias ADK.Session.Store.VertexAI

  @moduletag :vertex_ai

  setup do
    Application.put_env(:adk, :vertex_session_test_plug, true)

    Req.Test.stub(VertexAI, fn conn ->
      url = conn.request_path

      cond do
        String.ends_with?(url, "/sessions/1") and conn.method == "GET" ->
          # test_get_and_delete_session (get)
          Req.Test.json(conn, %{
            "name" =>
              "projects/test-project/locations/test-location/reasoningEngines/123/sessions/1",
            "userId" => "user",
            "sessionState" => %{"key" => "test_value"}
          })

        String.ends_with?(url, "/sessions/1/events") and conn.method == "GET" ->
          Req.Test.json(conn, %{
            "events" => [
              %{
                "name" =>
                  "projects/test-project/locations/test-location/reasoningEngines/123/sessions/1/events/123",
                "invocationId" => "123",
                "author" => "user",
                "timestamp" => "2024-12-12T12:12:12.123456Z",
                "content" => %{"parts" => [%{"text" => "test_content"}]},
                "actions" => %{
                  "stateDelta" => %{"key" => "test_value"},
                  "transferAgent" => "agent"
                },
                "eventMetadata" => %{
                  "partial" => false,
                  "turnComplete" => true,
                  "interrupted" => false,
                  "branch" => "",
                  "longRunningToolIds" => ["tool1"]
                }
              }
            ]
          })

        String.ends_with?(url, "/sessions/1") and conn.method == "DELETE" ->
          Req.Test.json(conn, %{})

        String.ends_with?(url, "/sessions/missing") and conn.method == "GET" ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => %{"code" => 404, "message" => "Not found"}})

        String.ends_with?(url, "/sessions/0") and conn.method == "GET" ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => %{"code" => 404, "message" => "Not found"}})

        String.ends_with?(url, "/sessions/2") and conn.method == "GET" ->
          # test_get_session_with_page_token
          Req.Test.json(conn, %{
            "name" =>
              "projects/test-project/locations/test-location/reasoningEngines/123/sessions/2",
            "userId" => "user",
            "sessionState" => %{}
          })

        String.ends_with?(url, "/sessions/2/events") and conn.method == "GET" ->
          # paginated
          case conn.query_params["pageToken"] do
            nil ->
              Req.Test.json(conn, %{
                "events" => [
                  %{
                    "name" =>
                      "projects/test-project/locations/test-location/reasoningEngines/123/sessions/2/events/123",
                    "invocationId" => "222",
                    "author" => "user",
                    "timestamp" => "2024-12-12T12:12:12.123456Z"
                  }
                ],
                "nextPageToken" => "my_token"
              })

            "my_token" ->
              Req.Test.json(conn, %{
                "events" => [
                  %{
                    "name" =>
                      "projects/test-project/locations/test-location/reasoningEngines/123/sessions/2/events/456",
                    "invocationId" => "333",
                    "author" => "user",
                    "timestamp" => "2024-12-12T12:12:13.123456Z"
                  }
                ]
              })
          end

        String.ends_with?(url, "/sessions") and conn.method == "GET" ->
          # list sessions
          sessions =
            if conn.query_params["filter"] == ~s(user_id="user") do
              [%{"name" => ".../sessions/1"}, %{"name" => ".../sessions/2"}]
            else
              [
                %{"name" => ".../sessions/1"},
                %{"name" => ".../sessions/2"},
                %{"name" => ".../sessions/3"}
              ]
            end

          Req.Test.json(conn, %{"sessions" => sessions})

        String.ends_with?(url, "/sessions") and conn.method == "POST" ->
          # create session
          Req.Test.json(conn, %{
            "name" =>
              "projects/test-project/locations/test-location/reasoningEngines/123/sessions/#{conn.query_params["sessionId"]}",
            "userId" => "user",
            "sessionState" => %{}
          })

        String.ends_with?(url, "events:appendEvent") and conn.method == "POST" ->
          Req.Test.json(conn, %{
            "name" => "...",
            "invocationId" => "new_invocation",
            "author" => "model",
            "timestamp" => "2024-12-12T12:12:13Z"
          })

        true ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => "unhandled route #{conn.method} #{url}"})
      end
    end)

    on_exit(fn ->
      Application.delete_env(:adk, :vertex_session_test_plug)
    end)

    :ok
  end

  # Helper to temporarily override env vars to test
  defp with_config(fun) do
    Application.put_env(:adk, :vertex_project_id, "test-project")
    Application.put_env(:adk, :vertex_location, "test-location")
    Application.put_env(:adk, :vertex_reasoning_engine_id, "123")
    Application.put_env(:adk, :vertex_api_key, "test-api-key")

    fun.()

    Application.delete_env(:adk, :vertex_project_id)
    Application.delete_env(:adk, :vertex_location)
    Application.delete_env(:adk, :vertex_reasoning_engine_id)
    Application.delete_env(:adk, :vertex_api_key)
  end

  test "load missing session returns not_found" do
    with_config(fn ->
      assert {:error, :not_found} = VertexAI.load("123", "user", "missing")
      assert {:error, :not_found} = VertexAI.load("123", "user", "0")
    end)
  end

  test "load session belonging to another user" do
    with_config(fn ->
      assert {:error, {:forbidden, _}} = VertexAI.load("123", "user2", "1")
    end)
  end

  test "load successfully fetches session and events" do
    with_config(fn ->
      assert {:ok, session} = VertexAI.load("123", "user", "1")
      assert session.id == "1"
      assert session.user_id == "user"
      assert session.state == %{"key" => "test_value"}
      assert length(session.events) == 1

      event = hd(session.events)
      assert event.id == "123"
      assert event.invocation_id == "123"
      assert event.actions.transfer_to_agent == "agent"
    end)
  end

  test "load session paginates events" do
    with_config(fn ->
      assert {:ok, session} = VertexAI.load("123", "user", "2")
      assert length(session.events) == 2
      assert Enum.at(session.events, 0).id == "123"
      assert Enum.at(session.events, 1).id == "456"
    end)
  end

  test "delete session" do
    with_config(fn ->
      assert :ok = VertexAI.delete("123", "user", "1")
    end)
  end

  test "list sessions" do
    with_config(fn ->
      sessions = VertexAI.list("123", "user")
      assert sessions == ["1", "2"]

      sessions_all = VertexAI.list("123", nil)
      assert sessions_all == ["1", "2", "3"]
    end)
  end

  test "save appends new events and creates missing session" do
    with_config(fn ->
      # We simulate saving a session that is missing.
      # It should hit GET /sessions/missing, 404
      # Then POST /sessions?sessionId=missing
      # Then POST /events:appendEvent for each event

      session = %ADK.Session{
        id: "missing",
        app_name: "123",
        user_id: "user",
        state: %{"key" => "value"},
        events: [
          %ADK.Event{
            invocation_id: "new_invocation",
            author: "model",
            timestamp: DateTime.utc_now(),
            actions: %ADK.EventActions{compaction: %ADK.EventCompaction{start_timestamp: 12345.0}}
          }
        ]
      }

      assert :ok = VertexAI.save(session)
    end)
  end

  test "sessions_url uses us-central1 by default" do
    # build_config([]) uses @default_location "us-central1"
    # We use a private helper via apply or just trust the logic?
    # Better: check the actual URL requested in the stub.
    
    Application.put_env(:adk, :vertex_project_id, "test-project")
    Application.delete_env(:adk, :vertex_location) # Force default
    
    parent = self()
    Req.Test.stub(VertexAI, fn conn ->
      send(parent, {:requested_url, conn.request_path, conn.host})
      Req.Test.json(conn, %{"sessions" => []})
    end)
    
    VertexAI.list("123", nil)
    
    assert_receive {:requested_url, _path, host}
    assert host == "us-central1-aiplatform.googleapis.com"
    
    Application.delete_env(:adk, :vertex_project_id)
  end

  test "save appends only new events to existing session" do
    with_config(fn ->
      session = %ADK.Session{
        id: "1",
        app_name: "123",
        user_id: "user",
        state: %{"key" => "test_value"},
        events: [
          %ADK.Event{
            id: "123",
            # this one exists in mock!
            invocation_id: "123",
            author: "user"
          },
          %ADK.Event{
            # this one does not
            invocation_id: "new_invocation_2",
            author: "model",
            timestamp: DateTime.utc_now(),
            actions: %ADK.EventActions{}
          }
        ]
      }

      # Should do GET /sessions/1 (exists)
      # Should GET /events, sees "123"
      # Should only POST new_invocation_2
      assert :ok = VertexAI.save(session)
    end)
  end
end
