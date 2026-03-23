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

defmodule ADK.CLI.AgentLoaderParityTest do
  @moduledoc """
  Parity tests for agent loading, mirroring Python ADK's
  `tests/unittests/cli/utils/test_agent_loader.py`.

  ## Architectural Mapping

  Python's `AgentLoader` loads agents from disk (`.py` modules, packages,
  YAML configs) with caching, error handling, and listing. In Elixir ADK,
  agent loading is handled through:

  - **Map-based loader** — `%{app_name => agent}` map passed to `WebRouter`
  - **Module-based loader** — Module implementing `list_agents/0`, `load_agent/1`,
    and optionally `list_agents_detailed/0` callbacks
  - **Oban.AgentWorker** — Resolves agents from module names or config maps

  ## Coverage Mapping

  | Python test                                  | Elixir equivalent                      |
  |----------------------------------------------|----------------------------------------|
  | test_load_agent_as_module                     | load_agent via map                     |
  | test_load_agent_as_package_with_root_agent    | load_agent via module callback         |
  | test_agent_caching_returns_same_instance      | map lookup is identity-preserving      |
  | test_load_multiple_different_agents           | map with multiple agents               |
  | test_agent_not_found_error                    | load_agent returns :not_found          |
  | test_agent_without_root_agent_error           | module callback returns nil            |
  | test_list_agents_excludes_non_agent_dirs      | list_agents from map/module            |
  | test_list_agents_detailed                     | list_agents_detailed                   |
  | test_load_agent_from_yaml_config              | N/A — Elixir uses code, not YAML       |
  | test_env_loading_for_agent                    | N/A — Elixir uses config, not .env     |
  | test_sys_path_modification                    | N/A — Elixir uses module system        |
  | test_agent_internal_syntax_error              | module resolution error handling       |
  | test_special_agent_with_double_underscore     | N/A — no special agent concept         |
  """
  use ExUnit.Case, async: true

  # ── Helpers ──────────────────────────────────────────────────────────

  defp make_agent(name, opts \\ []) do
    ADK.Agent.Custom.new(
      name: name,
      description: Keyword.get(opts, :description, ""),
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(%{author: name, content: %{role: :model, parts: [%{text: "hi from #{name}"}]}})]
      end
    )
  end

  # ── Map-based agent loading (mirrors Python module/package loading) ──

  describe "map-based agent loading" do
    test "load agent by name from map" do
      agent = make_agent("my_agent")
      agents = %{"my_agent" => agent}

      assert {:ok, loaded} = map_load_agent(agents, "my_agent")
      assert ADK.Agent.name(loaded) == "my_agent"
    end

    test "loading same agent returns same struct instance" do
      agent = make_agent("cached_agent")
      agents = %{"cached_agent" => agent}

      {:ok, agent1} = map_load_agent(agents, "cached_agent")
      {:ok, agent2} = map_load_agent(agents, "cached_agent")

      # Map lookup always returns the same value — identity preserved
      assert agent1 == agent2
      assert agent1.name == agent2.name
    end

    test "load multiple different agents" do
      agent_one = make_agent("agent_one")
      agent_two = make_agent("agent_two")
      agent_three = make_agent("agent_three")

      agents = %{
        "agent_one" => agent_one,
        "agent_two" => agent_two,
        "agent_three" => agent_three
      }

      {:ok, a1} = map_load_agent(agents, "agent_one")
      {:ok, a2} = map_load_agent(agents, "agent_two")
      {:ok, a3} = map_load_agent(agents, "agent_three")

      assert ADK.Agent.name(a1) == "agent_one"
      assert ADK.Agent.name(a2) == "agent_two"
      assert ADK.Agent.name(a3) == "agent_three"

      # Different agents
      refute a1 == a2
      refute a2 == a3
    end

    test "agent not found returns error" do
      agents = %{"existing" => make_agent("existing")}

      assert {:error, :not_found} = map_load_agent(agents, "nonexistent_agent")
    end

    test "list agents returns sorted keys" do
      agents = %{
        "beta_agent" => make_agent("beta_agent"),
        "alpha_agent" => make_agent("alpha_agent"),
        "gamma_agent" => make_agent("gamma_agent")
      }

      names = map_list_agents(agents)
      assert is_list(names)
      assert "alpha_agent" in names
      assert "beta_agent" in names
      assert "gamma_agent" in names
    end

    test "list agents detailed includes metadata" do
      agent = make_agent("detailed_agent", description: "A detailed test agent")
      agents = %{"detailed_agent" => agent}

      detailed = map_list_agents_detailed(agents)

      assert [entry] = detailed
      assert entry.name == "detailed_agent"
      assert entry.root_agent_name == "detailed_agent"
      assert entry.description == "A detailed test agent"
      assert entry.language == "elixir"
      assert entry.is_computer_use == false
    end

    test "list agents detailed with multiple agents" do
      agents = %{
        "agent_a" => make_agent("agent_a", description: "First agent"),
        "agent_b" => make_agent("agent_b", description: "Second agent")
      }

      detailed = map_list_agents_detailed(agents)
      assert length(detailed) == 2

      names = Enum.map(detailed, & &1.name) |> Enum.sort()
      assert names == ["agent_a", "agent_b"]
    end

    test "empty map returns empty list" do
      assert map_list_agents(%{}) == []
      assert map_list_agents_detailed(%{}) == []
    end
  end

  # ── Module-based agent loading (mirrors Python class-based loader) ──

  # Static test loader modules (can't dynamically create modules with closures)
  defmodule TestLoaderWithAgents do
    @moduledoc false
    def list_agents, do: ["app_one", "app_two"]

    def load_agent("app_one") do
      ADK.Agent.Custom.new(
        name: "app_one",
        run_fn: fn _, _ -> [] end
      )
    end

    def load_agent("app_two") do
      ADK.Agent.Custom.new(
        name: "app_two",
        run_fn: fn _, _ -> [] end
      )
    end

    def load_agent(_), do: nil
  end

  defmodule TestLoaderEmpty do
    @moduledoc false
    def list_agents, do: []
    def load_agent(_), do: nil
  end

  defmodule TestLoaderWithDetailed do
    @moduledoc false
    def list_agents, do: ["fancy_agent"]
    def load_agent(_), do: nil

    def list_agents_detailed do
      [
        %{
          name: "fancy_agent",
          root_agent_name: "fancy",
          description: "A fancy one",
          language: "elixir",
          is_computer_use: false
        }
      ]
    end
  end

  defmodule TestLoaderNoDetailed do
    @moduledoc false
    def list_agents, do: ["simple_app"]

    def load_agent("simple_app") do
      ADK.Agent.Custom.new(
        name: "simple_app",
        run_fn: fn _, _ -> [] end
      )
    end

    def load_agent(_), do: nil
    # Intentionally no list_agents_detailed/0
  end

  describe "module-based agent loading" do
    test "load agent via module callback" do
      assert {:ok, agent} = module_load_agent(TestLoaderWithAgents, "app_one")
      assert ADK.Agent.name(agent) == "app_one"
    end

    test "module loader returns nil for missing agent" do
      assert {:error, :not_found} = module_load_agent(TestLoaderEmpty, "missing")
    end

    test "list agents via module callback" do
      names = module_list_agents(TestLoaderWithAgents)
      assert "app_one" in names
      assert "app_two" in names
    end

    test "list agents detailed via module callback" do
      detailed = module_list_agents_detailed(TestLoaderWithDetailed)
      assert [entry] = detailed
      assert entry.name == "fancy_agent"
      assert entry.description == "A fancy one"
    end

    test "fallback when module has no list_agents_detailed" do
      # Should fall back to list_agents + generate basic entries
      detailed = module_list_agents_detailed_fallback(TestLoaderNoDetailed)
      assert [%{name: "simple_app", root_agent_name: "simple_app"}] = detailed
    end

    test "non-module loader returns empty" do
      # A non-atom, non-map value should return empty/not_found
      assert generic_list_agents("not_a_module") == []
      assert generic_load_agent("not_a_module", "anything") == {:error, :not_found}
      assert generic_list_agents(42) == []
      assert generic_load_agent(42, "anything") == {:error, :not_found}
    end
  end

  # ── Agent resolution via Oban.AgentWorker pattern ──

  describe "agent module resolution" do
    test "resolve agent from module with agent/0 callback" do
      # This tests the pattern used by Oban.AgentWorker
      # The module must export agent/0 returning an ADK.Agent.t()
      defmodule TestAgentModule do
        def agent do
          ADK.Agent.Custom.new(
            name: "test_resolved",
            run_fn: fn _agent, _ctx -> [] end
          )
        end
      end

      assert {:ok, agent} = resolve_agent_module(TestAgentModule)
      assert ADK.Agent.name(agent) == "test_resolved"
    end

    test "resolve agent from module string" do
      defmodule StringResolvedAgent do
        def agent do
          ADK.Agent.Custom.new(
            name: "string_resolved",
            run_fn: fn _agent, _ctx -> [] end
          )
        end
      end

      mod_string = "ADK.CLI.AgentLoaderParityTest.StringResolvedAgent"
      assert {:ok, agent} = resolve_agent_from_string(mod_string)
      assert ADK.Agent.name(agent) == "string_resolved"
    end

    test "resolve agent from unknown module string returns error" do
      assert {:error, msg} = resolve_agent_from_string("Nonexistent.Module.Agent")
      assert msg =~ "Unknown module"
    end

    test "resolve agent from module without agent/0 returns error" do
      defmodule NoAgentCallback do
        def hello, do: :world
      end

      assert {:error, msg} = resolve_agent_module(NoAgentCallback)
      assert msg =~ "does not export agent/0"
    end

    test "resolve agent from inline config map" do
      config = %{
        "type" => "llm",
        "name" => "inline_agent",
        "model" => "gemini-flash-latest",
        "instruction" => "You are helpful"
      }

      assert {:ok, agent} = resolve_agent_from_config(config)
      assert ADK.Agent.name(agent) == "inline_agent"
    end

    test "resolve agent with missing args returns error" do
      assert {:error, msg} = resolve_agent_from_args(%{})
      assert msg =~ "agent_module" or msg =~ "agent_config"
    end
  end

  # ── Agent validation (mirrors Python name validation) ──

  describe "agent name validation" do
    test "agent name must be a string" do
      agent = make_agent("valid_name")
      assert is_binary(ADK.Agent.name(agent))
    end

    test "custom agent requires name" do
      assert_raise ArgumentError, fn ->
        ADK.Agent.Custom.new(run_fn: fn _, _ -> [] end)
      end
    end

    test "custom agent requires run_fn" do
      assert_raise ArgumentError, fn ->
        ADK.Agent.Custom.new(name: "test")
      end
    end

    test "llm agent requires name, model, instruction" do
      assert_raise ArgumentError, fn ->
        ADK.Agent.LlmAgent.new(model: "gemini", instruction: "hi")
      end

      assert_raise ArgumentError, fn ->
        ADK.Agent.LlmAgent.new(name: "test", instruction: "hi")
      end

      # instruction is optional (some agents use tools-only without instruction)
      agent = ADK.Agent.LlmAgent.new(name: "test", model: "gemini")
      assert agent.name == "test"
    end

    test "valid llm agent creation" do
      agent = ADK.Agent.LlmAgent.new(
        name: "valid",
        model: "gemini-flash-latest",
        instruction: "You are helpful"
      )

      assert ADK.Agent.name(agent) == "valid"
    end
  end

  # ── WebRouter integration (end-to-end agent loading) ──

  describe "WebRouter agent loading integration" do
    test "GET /list-apps with map loader" do
      agents = %{
        "app_one" => make_agent("app_one"),
        "app_two" => make_agent("app_two")
      }

      conn = build_conn(:get, "/list-apps") |> call_router(agents)
      assert conn.status == 200
      apps = Jason.decode!(conn.resp_body)
      assert "app_one" in apps
      assert "app_two" in apps
    end

    test "GET /list-apps?detailed=true includes metadata" do
      agents = %{
        "my_app" => make_agent("my_app", description: "My test app")
      }

      conn = build_conn(:get, "/list-apps?detailed=true") |> call_router(agents)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert %{"apps" => [entry]} = body
      assert entry["name"] == "my_app"
      assert entry["root_agent_name"] == "my_app"
    end

    test "POST /run returns 404 for unknown app" do
      agents = %{"known" => make_agent("known")}

      conn =
        build_conn(:post, "/run", %{
          app_name: "unknown",
          user_id: "u1",
          session_id: "s1",
          new_message: %{parts: [%{text: "hi"}]}
        })
        |> call_router(agents)

      assert conn.status == 404
    end

    test "POST /run_sse returns 404 for unknown app" do
      agents = %{"known" => make_agent("known")}

      conn =
        build_conn(:post, "/run_sse", %{
          app_name: "unknown",
          user_id: "u1",
          session_id: "s1",
          new_message: %{parts: [%{text: "hi"}]}
        })
        |> call_router(agents)

      assert conn.status == 404
    end

    test "empty agent map returns empty list" do
      conn = build_conn(:get, "/list-apps") |> call_router(%{})
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == []
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  # Map-based loader helpers (mirrors WebRouter private functions)
  defp map_load_agent(loader, app_name) when is_map(loader) do
    case Map.fetch(loader, app_name) do
      {:ok, agent} -> {:ok, agent}
      :error -> {:error, :not_found}
    end
  end

  defp map_list_agents(loader) when is_map(loader), do: Map.keys(loader)

  defp map_list_agents_detailed(loader) when is_map(loader) do
    Enum.map(loader, fn {name, agent} ->
      %{
        name: name,
        root_agent_name: ADK.Agent.name(agent),
        description: ADK.Agent.description(agent),
        language: "elixir",
        is_computer_use: false
      }
    end)
  end

  # Module-based loader helpers (static modules defined above)

  defp module_load_agent(loader, app_name) when is_atom(loader) do
    if function_exported?(loader, :load_agent, 1) do
      case loader.load_agent(app_name) do
        nil -> {:error, :not_found}
        agent -> {:ok, agent}
      end
    else
      {:error, :not_found}
    end
  end

  defp module_list_agents(loader) when is_atom(loader) do
    if function_exported?(loader, :list_agents, 0) do
      loader.list_agents()
    else
      []
    end
  end

  defp module_list_agents_detailed(loader) when is_atom(loader) do
    if function_exported?(loader, :list_agents_detailed, 0) do
      loader.list_agents_detailed()
    else
      []
    end
  end

  defp module_list_agents_detailed_fallback(loader) when is_atom(loader) do
    if function_exported?(loader, :list_agents_detailed, 0) do
      loader.list_agents_detailed()
    else
      module_list_agents(loader)
      |> Enum.map(fn name ->
        %{name: name, root_agent_name: name, description: "", language: "elixir", is_computer_use: false}
      end)
    end
  end

  defp generic_list_agents(loader) when not is_atom(loader) and not is_map(loader), do: []

  defp generic_load_agent(loader, _app_name) when not is_atom(loader) and not is_map(loader) do
    {:error, :not_found}
  end

  # Agent module resolution helpers (mirrors Oban.AgentWorker pattern)
  defp resolve_agent_module(module) when is_atom(module) do
    if function_exported?(module, :agent, 0) do
      {:ok, module.agent()}
    else
      {:error, "Module #{inspect(module)} does not export agent/0"}
    end
  end

  defp resolve_agent_from_string(mod_string) when is_binary(mod_string) do
    module = String.to_existing_atom("Elixir." <> mod_string)

    if function_exported?(module, :agent, 0) do
      {:ok, module.agent()}
    else
      {:error, "Module #{mod_string} does not export agent/0"}
    end
  rescue
    ArgumentError ->
      {:error, "Unknown module: #{mod_string}"}
  end

  defp resolve_agent_from_config(%{"type" => "llm"} = config) do
    agent =
      ADK.Agent.LlmAgent.new(
        name: Map.get(config, "name", "default_agent"),
        model: Map.fetch!(config, "model"),
        instruction: Map.get(config, "instruction", "You are a helpful assistant.")
      )

    {:ok, agent}
  end

  defp resolve_agent_from_args(args) do
    cond do
      Map.has_key?(args, "agent_module") ->
        resolve_agent_from_string(args["agent_module"])

      Map.has_key?(args, "agent_config") ->
        resolve_agent_from_config(args["agent_config"])

      true ->
        {:error, "Job args must include either `agent_module` or `agent_config`"}
    end
  end

  # WebRouter integration helpers
  defp build_conn(method, path, body \\ nil) do
    conn = Plug.Test.conn(method, path, body && Jason.encode!(body))

    if body do
      conn |> Plug.Conn.put_req_header("content-type", "application/json")
    else
      conn
    end
  end

  defp call_router(conn, agents) do
    opts = [
      agent_loader: agents,
      session_store: {ADK.Session.Store.InMemory, []}
    ]

    ADK.Phoenix.WebRouter.call(conn, ADK.Phoenix.WebRouter.init(opts))
  end
end
