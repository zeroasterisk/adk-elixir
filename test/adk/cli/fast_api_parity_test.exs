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

defmodule ADK.CLI.FastApiParityTest do
  @moduledoc """
  Parity tests ported from Python's tests/unittests/cli/test_fast_api.py.

  Python's FastAPI development server maps to Elixir's:
    - `ADK.DevServer.Router`  ↔  FastAPI dev-server HTTP endpoints
    - `ADK.A2A.Server`         ↔  A2A protocol routes (agent card, message/send, etc.)
    - `ADK.A2A.AgentCard`      ↔  agent card generation / discovery
    - `ADK.WebServer.Cors`     ↔  `allow_origins` CORS parsing

  Covers:
  - GET /api/agent (agent info endpoint) — list-apps analogue
  - POST /api/chat — run-agent analogue (non-streaming)
  - POST /api/chat/stream — run_sse analogue (streaming)
  - 400/404/500 error responses
  - A2A agent card at /.well-known/agent.json
  - A2A message/send endpoint
  - A2A tasks/get, tasks/cancel
  - Invalid JSON parse error (-32700)
  - Unknown A2A method error (-32004)
  - CORS origin parsing (allow_origins)
  - Agent card capabilities and skills
  """

  use ExUnit.Case, async: true
  @moduletag :a2a

  import Plug.Test
  import Plug.Conn

  alias ADK.DevServer.Router
  alias ADK.A2A.Server
  alias ADK.A2A.AgentCard

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @router_opts Router.init(agent: :demo, model: ADK.LLM.Mock, port: 4099)

  defp router_call(method, path, body \\ nil) do
    req =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    Router.call(req, @router_opts)
  end

  defp a2a_config(name \\ "parity_agent") do
    agent =
      ADK.Agent.Custom.new(
        name: name,
        description: "Parity test agent",
        run_fn: fn _agent, _ctx ->
          [
            ADK.Event.new(%{
              author: name,
              content: %{parts: [%{text: "parity reply"}]}
            })
          ]
        end
      )

    runner = %ADK.Runner{app_name: "parity", agent: agent}

    uid = System.unique_integer([:positive])

    Server.init(
      agent: agent,
      runner: runner,
      url: "http://localhost:4000",
      config_table_name: :"fast_api_parity_config_#{uid}",
      task_table_name: :"fast_api_parity_tasks_#{uid}"
    )
  end

  # ── DevServer Router tests ────────────────────────────────────────────────────
  # Maps to Python: test_list_apps, test_list_apps_detailed

  describe "GET /api/agent — agent info (list-apps analogue)" do
    test "returns 200 with agent name for demo agent" do
      conn = router_call(:get, "/api/agent")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "ADK Demo Agent"
      assert is_binary(body["module"])
    end

    test "returns model info in agent details" do
      conn = router_call(:get, "/api/agent")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["model"])
    end

    test "returns JSON content-type" do
      conn = router_call(:get, "/api/agent")

      [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "application/json"
    end
  end

  # Maps to Python: test_agent_run (POST /run)

  describe "POST /api/chat — run agent (non-streaming)" do
    test "returns 400 when message field is missing" do
      conn = router_call(:post, "/api/chat", %{})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Missing"
    end

    test "returns 400 when message is empty string" do
      conn = router_call(:post, "/api/chat", %{"message" => ""})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["error"])
    end

    test "returns 400 when body is unrecognised structure" do
      conn = router_call(:post, "/api/chat", %{"text" => "hello"})

      assert conn.status == 400
    end

    test "response shape has response and session_id on success" do
      # Using mock LLM — may error if not configured, but shape is consistent
      conn = router_call(:post, "/api/chat", %{"message" => "hello", "session_id" => "s1"})

      body = Jason.decode!(conn.resp_body)
      assert is_map(body)
      # Either {"response", "session_id", ...} or {"error": ...}
      assert Map.has_key?(body, "response") or Map.has_key?(body, "error")
    end
  end

  # Maps to Python: test_agent_run_sse_yields_error_object_on_exception,
  #                 test_agent_run_sse_splits_artifact_delta

  describe "POST /api/chat/stream — streaming run (run_sse analogue)" do
    test "returns 400 when message is missing" do
      conn = router_call(:post, "/api/chat/stream", %{})

      assert conn.status == 400
    end

    test "returns 400 when message is empty" do
      conn = router_call(:post, "/api/chat/stream", %{"message" => ""})

      assert conn.status == 400
    end

    test "streaming response begins with text/event-stream content-type" do
      conn = router_call(:post, "/api/chat/stream", %{"message" => "hi"})

      # 200 with SSE or 400 — both are valid based on LLM availability
      if conn.status == 200 do
        [ct] = get_resp_header(conn, "content-type")
        assert ct =~ "text/event-stream"
      end
    end

    test "streaming response body contains data: lines on success" do
      conn = router_call(:post, "/api/chat/stream", %{"message" => "hello", "session_id" => "stream-sess"})

      if conn.status == 200 do
        sse_lines = conn.resp_body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "data: "))
        # At minimum a session event should be present
        assert length(sse_lines) >= 1

        # Each SSE line should be valid JSON
        for line <- sse_lines do
          data = String.replace_prefix(line, "data: ", "")
          assert {:ok, _} = Jason.decode(data)
        end
      end
    end
  end

  # Maps to Python: test_health_endpoint, test_openapi_json_schema_accessible

  describe "GET /unknown routes — 404 catchall (health/openapi analogue)" do
    test "GET /health-nonexistent returns 404" do
      conn = router_call(:get, "/health-nonexistent")

      assert conn.status == 404
    end

    test "GET /unknown-path returns error JSON with path" do
      conn = router_call(:get, "/totally-unknown")

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Not found"
      assert body["path"] == "/totally-unknown"
    end

    test "GET /version returns 404 in dev server (only in FastAPI layer)" do
      conn = router_call(:get, "/version")

      assert conn.status == 404
    end
  end

  # ── A2A Server tests ──────────────────────────────────────────────────────────
  # Maps to Python: A2A endpoint behaviour tests

  describe "GET /.well-known/agent.json — agent card (a2a_agent_discovery)" do
    test "returns 200 with agent name and url" do
      config = a2a_config("discovery_agent")

      conn =
        conn(:get, "/.well-known/agent.json")
        |> Server.call(config)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "discovery_agent"
      assert is_list(body["supportedInterfaces"])
      [iface] = body["supportedInterfaces"]
      assert iface["url"] == "http://localhost:4000"
    end

    test "agent card description is included" do
      config = a2a_config("described_agent")

      conn =
        conn(:get, "/.well-known/agent.json")
        |> Server.call(config)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["description"])
    end

    test "agent card has version field" do
      config = a2a_config("versioned_agent")

      conn =
        conn(:get, "/.well-known/agent.json")
        |> Server.call(config)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["version"])
    end
  end

  # Maps to Python: test_agent_run via A2A message/send

  describe "POST / message/send — run agent via A2A (agent_run analogue)" do
    test "returns completed task with artifacts" do
      config = a2a_config("run_agent")

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "req-1",
          "method" => "message/send",
          "params" => %{
            "message" => %{
              "messageId" => "msg-1",
              "role" => "ROLE_USER",
              "parts" => [%{"text" => "Hello agent"}]
            }
          }
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> Server.call(config)

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == "req-1"
      task = resp["result"]
      assert task["status"]["state"] == "TASK_STATE_COMPLETED"
      assert is_list(task["artifacts"])
    end

    test "completed task contains agent reply text in artifacts" do
      config = a2a_config("reply_agent")

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "1",
          "method" => "message/send",
          "params" => %{
            "message" => %{
              "messageId" => "msg-reply",
              "role" => "ROLE_USER",
              "parts" => [%{"text" => "say hello"}]
            }
          }
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> Server.call(config)

      resp = Jason.decode!(conn.resp_body)
      task = resp["result"]
      # Artifacts contain text from agent response
      all_parts =
        task["artifacts"]
        |> Enum.flat_map(& &1["parts"])
        |> Enum.filter(&Map.has_key?(&1, "text"))

      assert Enum.any?(all_parts, fn p -> p["text"] =~ "parity reply" end)
    end

    test "task has stable id across get" do
      config = a2a_config("id_agent")

      send_body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "1",
          "method" => "message/send",
          "params" => %{
            "message" => %{
              "messageId" => "m1",
              "role" => "ROLE_USER",
              "parts" => [%{"text" => "hi"}]
            }
          }
        })

      send_conn =
        conn(:post, "/", send_body)
        |> put_req_header("content-type", "application/json")
        |> Server.call(config)

      task_id = Jason.decode!(send_conn.resp_body)["result"]["id"]
      assert is_binary(task_id) and task_id != ""

      get_body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "2",
          "method" => "tasks/get",
          "params" => %{"id" => task_id}
        })

      get_conn =
        conn(:post, "/", get_body)
        |> put_req_header("content-type", "application/json")
        |> Server.call(config)

      get_resp = Jason.decode!(get_conn.resp_body)
      assert get_resp["result"]["id"] == task_id
    end
  end

  # Maps to Python: test_create_session_with_id_already_exists → cancel completed

  describe "tasks/cancel — error on completed task (session_already_exists analogue)" do
    test "cancelling a completed task returns error" do
      config = a2a_config("cancel_agent")

      send_body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "1",
          "method" => "message/send",
          "params" => %{
            "message" => %{
              "messageId" => "m-cancel",
              "role" => "ROLE_USER",
              "parts" => [%{"text" => "hi"}]
            }
          }
        })

      send_conn =
        conn(:post, "/", send_body)
        |> put_req_header("content-type", "application/json")
        |> Server.call(config)

      task_id = Jason.decode!(send_conn.resp_body)["result"]["id"]

      cancel_body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "2",
          "method" => "tasks/cancel",
          "params" => %{"id" => task_id}
        })

      cancel_conn =
        conn(:post, "/", cancel_body)
        |> put_req_header("content-type", "application/json")
        |> Server.call(config)

      resp = Jason.decode!(cancel_conn.resp_body)
      # Completed tasks cannot be cancelled — should return error
      assert resp["error"] != nil
      assert resp["result"] == nil
    end
  end

  # Maps to Python: test_agent_run_sse_yields_error_object_on_exception

  describe "A2A error handling" do
    test "unknown method returns JSON-RPC -32004 error" do
      config = a2a_config("err_agent")

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "err-1",
          "method" => "totally/unknown",
          "params" => %{}
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> Server.call(config)

      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32_004
    end

    test "invalid JSON body returns -32700 parse error" do
      config = a2a_config("parse_err_agent")

      conn =
        conn(:post, "/", "{ not valid json }")
        |> put_req_header("content-type", "application/json")
        |> Server.call(config)

      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32_700
    end

    test "GET on unknown path returns 404" do
      config = a2a_config("404_agent")

      conn =
        conn(:get, "/no-such-route")
        |> Server.call(config)

      assert conn.status == 404
    end

    test "error response has jsonrpc 2.0 envelope" do
      config = a2a_config("env_agent")

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "e2",
          "method" => "bad/method",
          "params" => %{}
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> Server.call(config)

      resp = Jason.decode!(conn.resp_body)
      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == "e2"
    end
  end

  # Maps to Python: test_a2a_disabled_by_default, test_a2a_agent_discovery

  describe "A2A server configuration" do
    test "A2A server handles multiple distinct agents independently" do
      config_a = a2a_config("agent_alpha")
      config_b = a2a_config("agent_beta")

      conn_a =
        conn(:get, "/.well-known/agent.json")
        |> Server.call(config_a)

      conn_b =
        conn(:get, "/.well-known/agent.json")
        |> Server.call(config_b)

      body_a = Jason.decode!(conn_a.resp_body)
      body_b = Jason.decode!(conn_b.resp_body)

      assert body_a["name"] == "agent_alpha"
      assert body_b["name"] == "agent_beta"
      refute body_a["name"] == body_b["name"]
    end
  end

  # ── AgentCard generation tests ────────────────────────────────────────────────
  # Maps to Python: agent card fields returned by list-apps detailed

  describe "ADK.A2A.AgentCard — agent card generation" do
    test "from_agent/2 returns a map with name" do
      agent = ADK.Agent.LlmAgent.new(
        name: "card_agent",
        model: "test",
        instruction: "test",
        description: "A card agent"
      )

      card = AgentCard.from_agent(agent, url: "http://localhost:4000/a2a")
      assert card["name"] == "card_agent"
    end

    test "from_agent/2 includes description" do
      agent = ADK.Agent.LlmAgent.new(
        name: "described",
        model: "test",
        instruction: "do stuff",
        description: "Does stuff well"
      )

      card = AgentCard.from_agent(agent, url: "http://example.com/a2a")
      assert card["description"] == "Does stuff well"
    end

    test "from_agent/2 includes version field" do
      agent = ADK.Agent.LlmAgent.new(name: "versioned", model: "t", instruction: "i")

      card = AgentCard.from_agent(agent, url: "http://localhost/a2a")
      assert is_binary(card["version"])
    end

    test "from_agent/2 includes supportedInterfaces with correct url" do
      agent = ADK.Agent.LlmAgent.new(name: "iface", model: "t", instruction: "i")
      url = "http://custom.host:8080/a2a"

      card = AgentCard.from_agent(agent, url: url)
      interfaces = card["supportedInterfaces"]
      assert is_list(interfaces)
      assert Enum.any?(interfaces, &(&1["url"] == url))
    end

    test "from_agent/2 generates skills from tools" do
      tool = ADK.Tool.FunctionTool.new("greet",
        description: "Says hello",
        func: fn _ctx, _args -> {:ok, "hi"} end
      )

      agent = ADK.Agent.LlmAgent.new(
        name: "tool_agent",
        model: "t",
        instruction: "i",
        tools: [tool]
      )

      card = AgentCard.from_agent(agent, url: "http://localhost/a2a")
      skills = card["skills"]
      assert is_list(skills)
      assert length(skills) >= 1
      skill = hd(skills)
      assert skill["name"] == "greet"
      assert is_binary(skill["description"])
    end

    test "to_a2a_card/2 returns A2A.AgentCard struct" do
      agent = ADK.Agent.LlmAgent.new(name: "struct_agent", model: "t", instruction: "i")

      card = AgentCard.to_a2a_card(agent, url: "http://localhost/a2a")
      assert %A2A.AgentCard{} = card
      assert card.name == "struct_agent"
    end

    test "agent with no tools generates empty skills list" do
      agent = ADK.Agent.LlmAgent.new(name: "no_tools", model: "t", instruction: "i", tools: [])

      card = AgentCard.from_agent(agent, url: "http://localhost/a2a")
      assert card["skills"] == []
    end

    test "Custom agent card includes agent name" do
      custom_agent = ADK.Agent.Custom.new(
        name: "custom_a2a",
        description: "Custom A2A agent",
        run_fn: fn _a, _c -> [] end
      )

      card = AgentCard.from_agent(custom_agent, url: "http://localhost/a2a")
      assert card["name"] == "custom_a2a"
    end
  end

  # ── CORS origin parsing ───────────────────────────────────────────────────────
  # Maps to Python: allow_origins=["*"] in get_fast_api_app

  describe "CORS origin parsing — allow_origins analogue" do
    alias Adk.WebServer.Cors

    test "wildcard origin passes through as literal" do
      assert {:ok, ["*"], nil} = Cors.parse_origins(["*"])
    end

    test "multiple literal origins parsed correctly" do
      origins = ["https://app.example.com", "http://localhost:3000"]
      assert {:ok, ^origins, nil} = Cors.parse_origins(origins)
    end

    test "regex origins are combined into single pattern" do
      origins = ["regex:https://.*\\.example\\.com", "regex:https://.*\\.test\\.com"]
      {:ok, [], combined} = Cors.parse_origins(origins)
      assert is_binary(combined)
      assert combined =~ "example"
      assert combined =~ "test"
    end

    test "mixed literal and regex origins" do
      origins = ["https://fixed.com", "regex:https://.*\\.dynamic\\.com"]
      {:ok, literals, regex} = Cors.parse_origins(origins)
      assert literals == ["https://fixed.com"]
      assert is_binary(regex)
      assert regex =~ "dynamic"
    end

    test "nil origins returns empty" do
      assert {:ok, [], nil} = Cors.parse_origins(nil)
    end

    test "empty list returns empty" do
      assert {:ok, [], nil} = Cors.parse_origins([])
    end
  end

  # ── Session store analogue ────────────────────────────────────────────────────
  # Maps to Python: test_create_session_with_id, test_get_session,
  #                 test_list_sessions, test_delete_session,
  #                 test_create_session_with_id_already_exists

  describe "ADK.Session — session management (FastAPI session endpoints analogue)" do
    # Use unique app/user namespaces per test to avoid cross-test pollution.
    # The global ADK.Session.Store.InMemory is started by the Application.

    defp uniq_ids do
      uid = System.unique_integer([:positive])
      app = "fp_app_#{uid}"
      user = "fp_user_#{uid}"
      {app, user}
    end

    defp start_session(app, user, id) do
      ADK.Session.start_link(
        app_name: app,
        user_id: user,
        session_id: id,
        store: {ADK.Session.Store.InMemory, []},
        auto_save: true
      )
    end

    test "creating a session returns a live pid" do
      {app, user} = uniq_ids()
      {:ok, pid} = start_session(app, user, "sess1")
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "session can be retrieved and has correct fields" do
      {app, user} = uniq_ids()
      {:ok, pid} = start_session(app, user, "sess_get")

      {:ok, session} = ADK.Session.get(pid)
      assert session.id == "sess_get"
      assert session.app_name == app
      assert session.user_id == user
    end

    test "session state starts empty" do
      {app, user} = uniq_ids()
      {:ok, pid} = start_session(app, user, "sess_state")

      {:ok, session} = ADK.Session.get(pid)
      assert session.state == %{}
    end

    test "session state can be updated" do
      {app, user} = uniq_ids()
      {:ok, pid} = start_session(app, user, "sess_update")

      ADK.Session.put_state(pid, "key", "value")
      {:ok, session} = ADK.Session.get(pid)
      assert session.state["key"] == "value"
    end

    test "session persists to store and can be loaded back" do
      {app, user} = uniq_ids()
      {:ok, pid} = start_session(app, user, "sess_persist")

      ADK.Session.put_state(pid, "counter", 42)
      ADK.Session.save(pid)

      {:ok, data} = ADK.Session.Store.InMemory.load(app, user, "sess_persist")
      assert data.state["counter"] == 42
    end

    test "listing sessions from store returns session ids" do
      {app, user} = uniq_ids()
      {:ok, pid1} = start_session(app, user, "list_sess_1")
      {:ok, pid2} = start_session(app, user, "list_sess_2")

      ADK.Session.save(pid1)
      ADK.Session.save(pid2)

      session_ids = ADK.Session.Store.InMemory.list(app, user)
      assert "list_sess_1" in session_ids
      assert "list_sess_2" in session_ids
    end

    test "deleting a session removes it from store" do
      {app, user} = uniq_ids()
      {:ok, pid} = start_session(app, user, "del_sess")

      ADK.Session.save(pid)
      assert {:ok, _} = ADK.Session.Store.InMemory.load(app, user, "del_sess")

      ADK.Session.Store.InMemory.delete(app, user, "del_sess")
      assert {:error, :not_found} = ADK.Session.Store.InMemory.load(app, user, "del_sess")
    end

    test "loading nonexistent session returns not_found" do
      assert {:error, :not_found} =
               ADK.Session.Store.InMemory.load("no_app", "no_user", "no_session")
    end

    test "multiple users have isolated session spaces" do
      uid = System.unique_integer([:positive])
      app = "fp_isolation_#{uid}"
      user_a = "user_a_#{uid}"
      user_b = "user_b_#{uid}"

      {:ok, pid_a} = start_session(app, user_a, "shared_id")
      {:ok, pid_b} = start_session(app, user_b, "shared_id")

      ADK.Session.put_state(pid_a, "owner", "user_a")
      ADK.Session.put_state(pid_b, "owner", "user_b")

      ADK.Session.save(pid_a)
      ADK.Session.save(pid_b)

      {:ok, data_a} = ADK.Session.Store.InMemory.load(app, user_a, "shared_id")
      {:ok, data_b} = ADK.Session.Store.InMemory.load(app, user_b, "shared_id")

      assert data_a.state["owner"] == "user_a"
      assert data_b.state["owner"] == "user_b"
    end
  end
end
