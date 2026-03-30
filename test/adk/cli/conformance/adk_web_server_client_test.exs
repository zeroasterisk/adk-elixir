# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Phoenix.WebServerClientTest do
  @moduledoc """
  Parity tests for `ADK.Phoenix.WebServerClient`, mirroring
  Python ADK's `tests/unittests/cli/conformance/test_adk_web_server_client.py`.

  Uses Bypass to mock the HTTP server rather than spawning a real server process.
  """

  use ExUnit.Case, async: true

  import Plug.Conn

  alias ADK.Phoenix.WebServerClient

  # --------------------------------------------------------------------------
  # Initialization tests
  # --------------------------------------------------------------------------

  describe "new/1" do
    test "default values" do
      client = WebServerClient.new()
      assert client.base_url == "http://127.0.0.1:8000"
      assert client.timeout == 30_000
    end

    test "custom base_url and timeout" do
      client = WebServerClient.new(base_url: "https://custom.example.com/", timeout: 60_000)
      assert client.base_url == "https://custom.example.com"
      assert client.timeout == 60_000
    end

    test "strips trailing slash from base_url" do
      client = WebServerClient.new(base_url: "http://test.com/")
      assert client.base_url == "http://test.com"
    end
  end

  # --------------------------------------------------------------------------
  # close/1
  # --------------------------------------------------------------------------

  describe "close/1" do
    test "returns :ok" do
      client = WebServerClient.new()
      assert :ok = WebServerClient.close(client)
    end
  end

  # --------------------------------------------------------------------------
  # Session CRUD
  # --------------------------------------------------------------------------

  describe "get_session/2" do
    test "returns session map on success" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "GET",
        "/apps/test_app/users/test_user/sessions/test_session",
        fn conn ->
          conn
          |> put_resp_content_type("application/json")
          |> resp(
            200,
            Jason.encode!(%{
              id: "test_session",
              app_name: "test_app",
              user_id: "test_user",
              events: [],
              state: %{}
            })
          )
        end
      )

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert {:ok, session} =
               WebServerClient.get_session(client,
                 app_name: "test_app",
                 user_id: "test_user",
                 session_id: "test_session"
               )

      assert session["id"] == "test_session"
      assert session["app_name"] == "test_app"
      assert session["user_id"] == "test_user"
    end

    test "returns error on 404" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "GET",
        "/apps/test_app/users/test_user/sessions/missing",
        fn conn ->
          conn
          |> put_resp_content_type("application/json")
          |> resp(404, Jason.encode!(%{detail: "Not found"}))
        end
      )

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert {:error, {:http_error, 404}} =
               WebServerClient.get_session(client,
                 app_name: "test_app",
                 user_id: "test_user",
                 session_id: "missing"
               )
    end
  end

  describe "create_session/2" do
    test "creates session and returns session map" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/apps/test_app/users/test_user/sessions", fn conn ->
        {:ok, body, conn} = read_body(conn)
        payload = Jason.decode!(body)
        assert payload["state"] == %{"key" => "value"}

        conn
        |> put_resp_content_type("application/json")
        |> resp(
          200,
          Jason.encode!(%{
            id: "new_session",
            app_name: "test_app",
            user_id: "test_user",
            events: [],
            state: %{"key" => "value"}
          })
        )
      end)

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert {:ok, session} =
               WebServerClient.create_session(client,
                 app_name: "test_app",
                 user_id: "test_user",
                 state: %{"key" => "value"}
               )

      assert session["id"] == "new_session"
      assert session["state"] == %{"key" => "value"}
    end

    test "creates session with empty state by default" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/apps/test_app/users/test_user/sessions", fn conn ->
        {:ok, body, conn} = read_body(conn)
        payload = Jason.decode!(body)
        assert payload["state"] == %{}

        conn
        |> put_resp_content_type("application/json")
        |> resp(
          200,
          Jason.encode!(%{
            id: "s1",
            app_name: "test_app",
            user_id: "test_user",
            events: [],
            state: %{}
          })
        )
      end)

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert {:ok, _session} =
               WebServerClient.create_session(client,
                 app_name: "test_app",
                 user_id: "test_user"
               )
    end
  end

  describe "delete_session/2" do
    test "returns :ok on success" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "DELETE",
        "/apps/test_app/users/test_user/sessions/test_session",
        fn conn ->
          resp(conn, 200, "")
        end
      )

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert :ok =
               WebServerClient.delete_session(client,
                 app_name: "test_app",
                 user_id: "test_user",
                 session_id: "test_session"
               )
    end

    test "returns :ok on 204" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "DELETE",
        "/apps/test_app/users/test_user/sessions/test_session",
        fn conn ->
          resp(conn, 204, "")
        end
      )

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert :ok =
               WebServerClient.delete_session(client,
                 app_name: "test_app",
                 user_id: "test_user",
                 session_id: "test_session"
               )
    end
  end

  describe "update_session/2" do
    test "sends state_delta and returns updated session" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "PATCH",
        "/apps/test_app/users/test_user/sessions/test_session",
        fn conn ->
          {:ok, body, conn} = read_body(conn)
          payload = Jason.decode!(body)
          assert payload["state_delta"] == %{"key" => "updated", "new_key" => "new_value"}

          conn
          |> put_resp_content_type("application/json")
          |> resp(
            200,
            Jason.encode!(%{
              id: "test_session",
              app_name: "test_app",
              user_id: "test_user",
              events: [],
              state: %{"key" => "updated", "new_key" => "new_value"}
            })
          )
        end
      )

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert {:ok, session} =
               WebServerClient.update_session(client,
                 app_name: "test_app",
                 user_id: "test_user",
                 session_id: "test_session",
                 state_delta: %{"key" => "updated", "new_key" => "new_value"}
               )

      assert session["id"] == "test_session"
      assert session["state"] == %{"key" => "updated", "new_key" => "new_value"}
    end
  end

  # --------------------------------------------------------------------------
  # run_agent/2
  # --------------------------------------------------------------------------

  describe "run_agent/2" do
    test "collects SSE events from streaming response" do
      bypass = Bypass.open()

      event1 = %{
        author: "test_agent",
        invocation_id: "inv_1",
        content: %{role: "model", parts: [%{text: "Hello"}]}
      }

      event2 = %{
        author: "test_agent",
        invocation_id: "inv_2",
        content: %{role: "model", parts: [%{text: "World"}]}
      }

      sse_body =
        "data:#{Jason.encode!(event1)}\n\n" <>
          "data:\n\n" <>
          "data:#{Jason.encode!(event2)}\n\n"

      Bypass.expect_once(bypass, "POST", "/run_sse", fn conn ->
        conn
        |> put_resp_content_type("text/event-stream")
        |> resp(200, sse_body)
      end)

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      request = %{
        app_name: "test_app",
        user_id: "test_user",
        session_id: "test_session",
        new_message: %{role: "user", parts: [%{text: "Hello"}]}
      }

      assert {:ok, events} = WebServerClient.run_agent(client, request)
      assert length(events) == 2
      assert Enum.at(events, 0)["invocation_id"] == "inv_1"
      assert Enum.at(events, 1)["invocation_id"] == "inv_2"
    end

    test "returns error when server streams an error payload" do
      bypass = Bypass.open()

      sse_body = ~s(data: {"error": "boom"}\n\n)

      Bypass.expect_once(bypass, "POST", "/run_sse", fn conn ->
        conn
        |> put_resp_content_type("text/event-stream")
        |> resp(200, sse_body)
      end)

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      request = %{
        app_name: "test_app",
        user_id: "test_user",
        session_id: "test_session",
        new_message: %{role: "user", parts: [%{text: "Hi"}]}
      }

      assert {:error, "boom"} = WebServerClient.run_agent(client, request)
    end

    test "returns http error on non-200 response" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/run_sse", fn conn ->
        resp(conn, 500, "Internal Server Error")
      end)

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert {:error, {:http_error, 500}} =
               WebServerClient.run_agent(client, %{
                 app_name: "test_app",
                 user_id: "test_user",
                 session_id: "test_session",
                 new_message: %{role: "user", parts: [%{text: "Hi"}]}
               })
    end
  end

  # --------------------------------------------------------------------------
  # parse_sse_body/1 (unit tests for the SSE parser)
  # --------------------------------------------------------------------------

  describe "parse_sse_body/1" do
    test "parses data lines into event maps" do
      body = "data:{\"id\":\"e1\"}\ndata:{\"id\":\"e2\"}\n"
      assert {:ok, [%{"id" => "e1"}, %{"id" => "e2"}]} = WebServerClient.parse_sse_body(body)
    end

    test "ignores empty data lines" do
      body = "data:\ndata:{\"id\":\"e1\"}\ndata:\n"
      assert {:ok, [%{"id" => "e1"}]} = WebServerClient.parse_sse_body(body)
    end

    test "ignores non-data lines" do
      body = "event: update\nid: 123\ndata:{\"id\":\"e1\"}\n"
      assert {:ok, [%{"id" => "e1"}]} = WebServerClient.parse_sse_body(body)
    end

    test "returns error on streamed error payload" do
      body = ~s(data: {"error": "something went wrong"}\n)
      assert {:error, "something went wrong"} = WebServerClient.parse_sse_body(body)
    end

    test "handles non-binary body" do
      assert {:ok, []} = WebServerClient.parse_sse_body(nil)
    end
  end

  # --------------------------------------------------------------------------
  # Artifact metadata
  # --------------------------------------------------------------------------

  describe "get_artifact_version_metadata/2" do
    test "returns artifact version metadata" do
      bypass = Bypass.open()

      metadata = %{
        version: 2,
        canonicalUri:
          "artifact://apps/app/users/user/sessions/session/artifacts/report/versions/2",
        customMetadata: %{"foo" => "bar"},
        createTime: 123.4,
        mimeType: "text/plain"
      }

      Bypass.expect_once(
        bypass,
        "GET",
        "/apps/app/users/user/sessions/session/artifacts/report/versions/2/metadata",
        fn conn ->
          conn
          |> put_resp_content_type("application/json")
          |> resp(200, Jason.encode!(metadata))
        end
      )

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert {:ok, result} =
               WebServerClient.get_artifact_version_metadata(client,
                 app_name: "app",
                 user_id: "user",
                 session_id: "session",
                 artifact_name: "report",
                 version: 2
               )

      assert result["version"] == 2
      assert result["customMetadata"] == %{"foo" => "bar"}
    end
  end

  describe "list_artifact_versions_metadata/2" do
    test "returns list of artifact version metadata" do
      bypass = Bypass.open()

      metadata_list = [
        %{
          version: 0,
          canonicalUri: "artifact://.../versions/0",
          customMetadata: %{},
          createTime: 100.0
        },
        %{
          version: 1,
          canonicalUri: "artifact://.../versions/1",
          customMetadata: %{"foo" => "bar"},
          createTime: 200.0,
          mimeType: "application/json"
        }
      ]

      Bypass.expect_once(
        bypass,
        "GET",
        "/apps/app/users/user/sessions/session/artifacts/report/versions/metadata",
        fn conn ->
          conn
          |> put_resp_content_type("application/json")
          |> resp(200, Jason.encode!(metadata_list))
        end
      )

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert {:ok, results} =
               WebServerClient.list_artifact_versions_metadata(client,
                 app_name: "app",
                 user_id: "user",
                 session_id: "session",
                 artifact_name: "report"
               )

      assert length(results) == 2
      assert Enum.at(results, 1)["customMetadata"] == %{"foo" => "bar"}
    end
  end

  # --------------------------------------------------------------------------
  # get_version_data/1
  # --------------------------------------------------------------------------

  describe "get_version_data/1" do
    test "returns version map" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/version", fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> resp(200, Jason.encode!(%{version: "1.2.3"}))
      end)

      client = WebServerClient.new(base_url: "http://localhost:#{bypass.port}")

      assert {:ok, %{"version" => "1.2.3"}} = WebServerClient.get_version_data(client)
    end
  end
end
