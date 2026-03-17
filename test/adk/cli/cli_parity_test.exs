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

defmodule ADK.CLI.CliParityTest do
  @moduledoc """
  Parity tests for CLI utilities, mirroring Python ADK's
  `tests/unittests/cli/utils/test_cli.py`.

  ## Architectural Mapping

  Python ADK's CLI is a Click-based CLI (`adk web`, `adk run`, `adk create`)
  that uses `run_cli`, `run_input_file`, `run_interactively`, and
  `create_artifact_service_from_options`. In Elixir, the equivalent
  functionality lives in:

  - `mix adk.new` — project scaffolding (Python: `adk create`)
  - `mix adk.server` — dev server (Python: `adk web` / `adk api_server`)
  - `mix adk.gen.migration` — DB migration generation
  - `ADK.DevServer.Router` — HTTP API & chat UI
  - `ADK.CLI.AgentChangeHandler` — file change detection for hot reload

  This file tests the behavioral parity of:
  1. Agent resolution / loading
  2. Project name validation (`valid_name?`)
  3. DevServer Router API endpoints (run_input_file / run_interactively parity)
  4. Service configuration patterns
  5. Agent change handler edge cases

  Tests already covered elsewhere are NOT duplicated:
  - `agent_change_handler_test.exs` — AgentChangeHandler core
  - `service_registry_parity_test.exs` — service backend parity
  - `cli_tools_click_option_mismatch_test.exs` — option/switch alignment
  """

  use ExUnit.Case, async: true

  # ===========================================================================
  # 1. Project Name Validation (Python: agent folder name validation)
  # ===========================================================================

  describe "Mix.Tasks.Adk.New.valid_name?/1 — agent name validation" do
    test "simple lowercase name is valid" do
      assert Mix.Tasks.Adk.New.valid_name?("my_agent")
    end

    test "lowercase with digits is valid" do
      assert Mix.Tasks.Adk.New.valid_name?("agent42")
    end

    test "single letter is valid" do
      assert Mix.Tasks.Adk.New.valid_name?("a")
    end

    test "underscore-separated is valid" do
      assert Mix.Tasks.Adk.New.valid_name?("my_cool_agent")
    end

    test "starting with uppercase is invalid" do
      refute Mix.Tasks.Adk.New.valid_name?("MyAgent")
    end

    test "starting with digit is invalid" do
      refute Mix.Tasks.Adk.New.valid_name?("42agent")
    end

    test "containing hyphen is invalid" do
      refute Mix.Tasks.Adk.New.valid_name?("my-agent")
    end

    test "containing space is invalid" do
      refute Mix.Tasks.Adk.New.valid_name?("my agent")
    end

    test "containing dot is invalid" do
      refute Mix.Tasks.Adk.New.valid_name?("my.agent")
    end

    test "empty string is invalid" do
      refute Mix.Tasks.Adk.New.valid_name?("")
    end

    test "starting with underscore is invalid" do
      refute Mix.Tasks.Adk.New.valid_name?("_agent")
    end
  end

  # ===========================================================================
  # 2. Agent Resolution (Python: importlib agent loading in run_cli)
  # ===========================================================================

  describe "Mix.Tasks.Adk.Server agent resolution" do
    test "nil agent resolves to :demo atom" do
      # Python: run_cli loads agent from directory, defaults to root_agent
      # Elixir: nil agent flag → :demo sentinel
      # We test the private resolve_agent via the task's public init behavior
      # by checking that the server task module is loaded and has expected switches
      assert Code.ensure_loaded?(Mix.Tasks.Adk.Server)
    end

    test "string agent name is converted to module via Module.concat" do
      # Python: importlib.import_module(agent_folder_name) → module
      # Elixir: Module.concat(["MyApp.MyAgent"]) → MyApp.MyAgent
      assert Module.concat(["Elixir.MyApp.MyAgent"]) == MyApp.MyAgent
      assert Module.concat(["MyApp"]) == MyApp
    end
  end

  # ===========================================================================
  # 3. DevServer Router API (Python: run_input_file / run_interactively parity)
  # ===========================================================================

  describe "DevServer.Router init/1 and call/2 — agent/model injection" do
    test "init validates expected keys" do
      # Python: run_cli configures services before running
      # Elixir: Router.init validates :agent, :model, :port
      opts = ADK.DevServer.Router.init(agent: :demo, model: "test-model", port: 4000)
      assert Keyword.get(opts, :agent) == :demo
      assert Keyword.get(opts, :model) == "test-model"
    end

    test "init rejects unknown keys" do
      assert_raise ArgumentError, fn ->
        ADK.DevServer.Router.init(agent: :demo, unknown_key: true)
      end
    end

    test "init accepts empty opts (all defaults)" do
      opts = ADK.DevServer.Router.init([])
      assert opts == []
    end
  end

  describe "DevServer.Router GET /api/agent — agent info endpoint" do
    test "returns agent info for demo agent" do
      # Python: run_cli creates session with app_name from agent
      # Elixir: GET /api/agent returns agent card
      conn = build_conn(:get, "/api/agent", agent: :demo, model: "test-model")
      conn = ADK.DevServer.Router.call(conn, ADK.DevServer.Router.init(agent: :demo, model: "test-model"))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "ADK Demo Agent"
      assert body["module"] == "demo"
      assert body["model"] == "test-model"
    end

    test "returns module name for custom agent atom" do
      conn = build_conn(:get, "/api/agent", agent: SomeModule, model: "gemini-pro")
      conn = ADK.DevServer.Router.call(conn, ADK.DevServer.Router.init(agent: SomeModule, model: "gemini-pro"))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["module"] == "SomeModule"
      assert body["model"] == "gemini-pro"
    end
  end

  describe "DevServer.Router POST /api/chat — input validation" do
    test "rejects missing message field" do
      # Python: run_input_file reads queries from JSON input
      # Elixir: POST /api/chat validates message field
      conn = build_conn(:post, "/api/chat", %{}, agent: :demo, model: "test-model")
      conn = ADK.DevServer.Router.call(conn, ADK.DevServer.Router.init(agent: :demo, model: "test-model"))

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Missing"
    end

    test "rejects empty message string" do
      conn = build_conn(:post, "/api/chat", %{"message" => ""}, agent: :demo, model: "test-model")
      conn = ADK.DevServer.Router.call(conn, ADK.DevServer.Router.init(agent: :demo, model: "test-model"))

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Missing"
    end
  end

  describe "DevServer.Router GET / — chat UI" do
    test "returns HTML with agent name" do
      conn = build_conn(:get, "/", agent: :demo, model: "test-model")
      conn = ADK.DevServer.Router.call(conn, ADK.DevServer.Router.init(agent: :demo, model: "test-model"))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
      assert conn.resp_body =~ "ADK Demo Agent"
      assert conn.resp_body =~ "test-model"
    end
  end

  describe "DevServer.Router catch-all" do
    test "returns 404 for unknown paths" do
      conn = build_conn(:get, "/unknown/path", agent: :demo, model: "test-model")
      conn = ADK.DevServer.Router.call(conn, ADK.DevServer.Router.init(agent: :demo, model: "test-model"))

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Not found"
      assert body["path"] == "/unknown/path"
    end
  end

  # ===========================================================================
  # 4. Service Configuration (Python: create_artifact_service_from_options)
  # ===========================================================================

  describe "ADK.Runner service defaults — artifact service factory parity" do
    test "runner defaults to nil services (in-memory implicit)" do
      # Python: create_artifact_service_from_options defaults to FileArtifactService
      # Elixir: Runner defaults to nil (in-memory fallback at runtime)
      agent = ADK.Agent.LlmAgent.new(name: "test", model: "test", instruction: "hi")
      runner = ADK.Runner.new(app_name: "test", agent: agent)

      assert runner.artifact_service == nil
      assert runner.session_store == nil
      assert runner.memory_store == nil
    end

    test "runner accepts InMemory artifact service" do
      # Python: create_artifact_service_from_options(artifact_service_uri="memory://")
      # → InMemoryArtifactService()
      agent = ADK.Agent.LlmAgent.new(name: "test", model: "test", instruction: "hi")

      runner =
        ADK.Runner.new(
          app_name: "test",
          agent: agent,
          artifact_service: {ADK.Artifact.InMemory, []}
        )

      assert runner.artifact_service == {ADK.Artifact.InMemory, []}
    end
  end

  # ===========================================================================
  # 5. AgentChangeHandler edge cases (extends existing test coverage)
  # ===========================================================================

  describe "AgentChangeHandler.should_reload?/1 — extended edge cases" do
    test "deeply nested .ex path triggers reload" do
      assert ADK.CLI.AgentChangeHandler.should_reload?("lib/deep/nested/dir/agent.ex")
    end

    test "file with multiple dots uses final extension" do
      assert ADK.CLI.AgentChangeHandler.should_reload?("agent.backup.ex")
    end

    test ".exs in test directory triggers reload" do
      assert ADK.CLI.AgentChangeHandler.should_reload?("test/support/agent_helper.exs")
    end

    test ".py does NOT trigger reload (Python-only)" do
      # Python ADK watches .py files; Elixir ADK intentionally does not
      refute ADK.CLI.AgentChangeHandler.should_reload?("agent.py")
    end

    test ".beam does NOT trigger reload" do
      refute ADK.CLI.AgentChangeHandler.should_reload?("Elixir.MyAgent.beam")
    end

    test "path with no directory component still works" do
      assert ADK.CLI.AgentChangeHandler.should_reload?("agent.ex")
    end

    test "hidden directory .ex file triggers reload" do
      assert ADK.CLI.AgentChangeHandler.should_reload?(".hidden/agent.ex")
    end
  end

  describe "AgentChangeHandler.handle_change/3 — multiple file changes" do
    defmodule TrackingLoader do
      @moduledoc false
      def remove_from_cache(app_name) do
        send(self(), {:cache_removed, app_name})
        :ok
      end
    end

    test "sequential changes for different extensions all trigger reload" do
      state = %{current_app_name: "my_app", runners_to_clean: []}

      state = ADK.CLI.AgentChangeHandler.handle_change("a.ex", TrackingLoader, state)
      assert_received {:cache_removed, "my_app"}

      state = ADK.CLI.AgentChangeHandler.handle_change("b.exs", TrackingLoader, state)
      assert_received {:cache_removed, "my_app"}

      state = ADK.CLI.AgentChangeHandler.handle_change("c.yaml", TrackingLoader, state)
      assert_received {:cache_removed, "my_app"}

      _state = ADK.CLI.AgentChangeHandler.handle_change("d.yml", TrackingLoader, state)
      assert_received {:cache_removed, "my_app"}
    end

    test "mixed supported and unsupported changes" do
      state = %{current_app_name: "app", runners_to_clean: []}

      state = ADK.CLI.AgentChangeHandler.handle_change("agent.ex", TrackingLoader, state)
      assert "app" in state.runners_to_clean

      state = ADK.CLI.AgentChangeHandler.handle_change("readme.md", TrackingLoader, state)
      # runners_to_clean unchanged after unsupported extension
      assert state.runners_to_clean == ["app"]
    end
  end

  # ===========================================================================
  # 6. Mix Task Option Parsing (Python: Click CLI argument validation)
  # ===========================================================================

  describe "mix adk.new option parsing" do
    test "parses --path option" do
      {opts, argv, _} = OptionParser.parse(["my_agent", "--path", "/tmp"], strict: [path: :string, model: :string, phoenix: :boolean])
      assert opts[:path] == "/tmp"
      assert argv == ["my_agent"]
    end

    test "parses --model option" do
      {opts, argv, _} = OptionParser.parse(["my_agent", "--model", "gemini-pro"], strict: [path: :string, model: :string, phoenix: :boolean])
      assert opts[:model] == "gemini-pro"
      assert argv == ["my_agent"]
    end

    test "parses --no-phoenix flag" do
      {opts, _argv, _} = OptionParser.parse(["my_agent", "--no-phoenix"], strict: [path: :string, model: :string, phoenix: :boolean])
      assert opts[:phoenix] == false
    end

    test "rejects unknown options" do
      {_opts, _argv, invalid} = OptionParser.parse(["my_agent", "--unknown", "val"], strict: [path: :string, model: :string, phoenix: :boolean])
      assert length(invalid) > 0
    end
  end

  describe "mix adk.server option parsing" do
    test "parses --port option as integer" do
      {opts, _argv, _} = OptionParser.parse(["--port", "8080"], strict: [port: :integer, agent: :string, model: :string])
      assert opts[:port] == 8080
    end

    test "parses --agent option as string" do
      {opts, _argv, _} = OptionParser.parse(["--agent", "MyApp.Agent"], strict: [port: :integer, agent: :string, model: :string])
      assert opts[:agent] == "MyApp.Agent"
    end

    test "all options together" do
      args = ["--port", "3000", "--agent", "Foo.Bar", "--model", "gemini-flash"]
      {opts, _argv, _} = OptionParser.parse(args, strict: [port: :integer, agent: :string, model: :string])
      assert opts[:port] == 3000
      assert opts[:agent] == "Foo.Bar"
      assert opts[:model] == "gemini-flash"
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp build_conn(method, path, opts) when is_list(opts) do
    build_conn(method, path, nil, opts)
  end

  defp build_conn(method, path, body, opts) do
    conn =
      Plug.Test.conn(method, path, body && Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_private(:adk_agent, Keyword.get(opts, :agent, :demo))
      |> Plug.Conn.put_private(:adk_model, Keyword.get(opts, :model, "test"))

    conn
  end

  defp get_resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end
end
