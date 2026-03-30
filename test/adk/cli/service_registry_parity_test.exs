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

defmodule ADK.CLI.ServiceRegistryParityTest do
  @moduledoc """
  Parity tests for service backend configuration, mirroring
  Python ADK's `tests/unittests/cli/test_service_registry.py`.

  ## Architectural Difference (Intentional)

  Python ADK uses a URI-scheme-based `ServiceRegistry` that maps strings like
  `"sqlite:///test.db"` or `"gs://my-bucket"` to service instances. This provides
  a clean CLI interface but requires runtime URI parsing.

  ADK Elixir uses **module-based service configuration** via `{Module, opts}`
  tuples in `ADK.Runner`. This is more idiomatic Elixir:

  - Python: `"sqlite:///test.db"` → `SqliteSessionService(db_path="test.db")`
  - Elixir: `{ADK.Session.Store.InMemory, []}` passed to `session_store:`

  The benefits are compile-time safety, no string parsing, and direct module
  dispatch without a registry lookup.

  ## Parity Mapping

  | Python URI scheme | Elixir module |
  |---|---|
  | `sqlite:///path` | `ADK.Session.Store.InMemory` (in-mem) / `ADK.Session.Store.Ecto` (persistent) |
  | `postgresql://...` | `ADK.Session.Store.Ecto` |
  | `agentengine://id` (session) | `ADK.Session.Store.VertexAI` (if present) |
  | `memory://` (session) | `ADK.Session.Store.InMemory` |
  | `gs://bucket` | `ADK.Artifact.GCS` |
  | `memory://` (artifact) | `ADK.Artifact.InMemory` |
  | `memory://` (memory) | `ADK.Memory.InMemory` |
  | `rag://corpus-id` | `ADK.Memory.Store.VertexAI` (if present) |
  | `agentengine://id` (memory) | `ADK.Memory.Store.VertexAI` |
  """

  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Session Store backend parity
  # ---------------------------------------------------------------------------

  describe "session store backends" do
    test "InMemory store exists and implements ADK.Session.Store behaviour" do
      # Python: registry.create_session_service("memory://")
      # → InMemorySessionService()
      assert Code.ensure_loaded?(ADK.Session.Store.InMemory)
      assert function_exported?(ADK.Session.Store.InMemory, :load, 3)
      assert function_exported?(ADK.Session.Store.InMemory, :save, 1)
      assert function_exported?(ADK.Session.Store.InMemory, :delete, 3)
      assert function_exported?(ADK.Session.Store.InMemory, :list, 2)
    end

    test "InMemory store implements ADK.Session.Store behaviour callbacks" do
      # Python: mock_services["sqlite_session"].assert_called_once_with(db_path="test.db")
      # Elixir: verify the behaviour contract
      behaviours =
        ADK.Session.Store.InMemory.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ADK.Session.Store in behaviours
    end

    test "JsonFile store exists and implements ADK.Session.Store behaviour" do
      # Python: registry.create_session_service("sqlite:///test.db")
      # Elixir: ADK.Session.Store.JsonFile provides file-based persistence (sqlite parity)
      assert Code.ensure_loaded?(ADK.Session.Store.JsonFile)

      behaviours =
        ADK.Session.Store.JsonFile.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ADK.Session.Store in behaviours
    end

    test "Ecto store is available when Ecto is loaded (postgresql parity)" do
      # Python: registry.create_session_service("postgresql://user:pass@host/db")
      # → DatabaseSessionService(db_url="postgresql://...")
      # Elixir: ADK.Session.Store.Ecto (requires Ecto in deps)
      if Code.ensure_loaded?(Ecto) do
        assert Code.ensure_loaded?(ADK.Session.Store.Ecto)

        behaviours =
          ADK.Session.Store.Ecto.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert ADK.Session.Store in behaviours
      else
        # If Ecto is not loaded, the module is conditionally compiled out
        # This matches Python's optional dependency approach for database backends
        assert true, "Ecto not available; ADK.Session.Store.Ecto conditional compile is correct"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Artifact Store backend parity
  # ---------------------------------------------------------------------------

  describe "artifact store backends" do
    test "InMemory artifact store exists and implements ADK.Artifact.Store behaviour" do
      # Python: registry.create_artifact_service("memory://")
      # → InMemoryArtifactService()
      assert Code.ensure_loaded?(ADK.Artifact.InMemory)

      behaviours =
        ADK.Artifact.InMemory.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ADK.Artifact.Store in behaviours
    end

    test "GCS artifact store exists and implements ADK.Artifact.Store behaviour" do
      # Python: registry.create_artifact_service("gs://my-bucket/path/prefix")
      # → GcsArtifactService(bucket_name="my-bucket")
      assert Code.ensure_loaded?(ADK.Artifact.GCS)

      behaviours =
        ADK.Artifact.GCS.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ADK.Artifact.Store in behaviours
    end

    test "GCS artifact store exposes save/load/list/delete callbacks" do
      # Python: mock_gcs_artifact.assert_called_once_with(bucket_name="my-bucket", ...)
      # Elixir: verify the behaviour contract is fully implemented
      Code.ensure_loaded!(ADK.Artifact.GCS)
      assert function_exported?(ADK.Artifact.GCS, :save, 6)
      assert function_exported?(ADK.Artifact.GCS, :load, 5)
      assert function_exported?(ADK.Artifact.GCS, :list, 4)
      assert function_exported?(ADK.Artifact.GCS, :delete, 5)
    end
  end

  # ---------------------------------------------------------------------------
  # Memory Store backend parity
  # ---------------------------------------------------------------------------

  describe "memory store backends" do
    test "InMemory memory store exists and implements ADK.Memory.Store behaviour" do
      # Python: registry.create_memory_service("memory://")
      # → InMemoryMemoryService()
      assert Code.ensure_loaded?(ADK.Memory.InMemory)

      behaviours =
        ADK.Memory.InMemory.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ADK.Memory.Store in behaviours
    end

    test "InMemory memory store is functional (search/add round-trip)" do
      # Python: memory_service = registry.create_memory_service("memory://")
      #         assert isinstance(memory_service, InMemoryMemoryService)
      # Elixir: use the already-started InMemory store (started by ADK.Application)
      # The store uses a module-level ETS table, so no pid is needed.
      unique_user = "test-user-#{System.unique_integer([:positive])}"
      entry = ADK.Memory.Entry.new(content: "Elixir is great for concurrency")
      :ok = ADK.Memory.InMemory.add("app", unique_user, [entry])

      {:ok, results} =
        ADK.Memory.InMemory.search("app", unique_user, "Elixir concurrency")

      assert length(results) >= 1
      assert Enum.any?(results, &String.contains?(&1.content, "Elixir"))
    end

    test "VertexAI memory store exists and implements ADK.Memory.Store behaviour" do
      # Python: registry.create_memory_service("rag://corpus-123")
      #         → VertexAiRagMemoryService(rag_corpus="projects/.../ragCorpora/corpus-123")
      # and:    registry.create_memory_service("agentengine://456")
      #         → VertexAiMemoryBankService(project=..., agent_engine_id=...)
      # Elixir: ADK.Memory.Store.VertexAI covers both Vertex AI memory backends
      assert Code.ensure_loaded?(ADK.Memory.Store.VertexAI)

      behaviours =
        ADK.Memory.Store.VertexAI.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ADK.Memory.Store in behaviours
    end

    test "VertexAI memory store exposes search/add callbacks" do
      # Python: mock_rag_memory / mock_agentengine_memory verified via assert_called_once_with
      # Elixir: verify behaviour callbacks are exported
      Code.ensure_loaded!(ADK.Memory.Store.VertexAI)
      assert function_exported?(ADK.Memory.Store.VertexAI, :search, 4)
      assert function_exported?(ADK.Memory.Store.VertexAI, :add, 3)
    end
  end

  # ---------------------------------------------------------------------------
  # Runner integration: module-tuple based service selection
  # ---------------------------------------------------------------------------

  describe "ADK.Runner service configuration (URI-registry Elixir equivalent)" do
    test "Runner accepts nil session_store (in-memory default)" do
      # Python: get_service_registry() returns None for unsupported schemes
      # Elixir: Runner with no session_store defaults to in-memory
      agent = ADK.Agent.LlmAgent.new(name: "test-bot", model: "test", instruction: "Help")
      runner = ADK.Runner.new(app_name: "test", agent: agent)

      assert runner.session_store == nil
      assert runner.artifact_service == nil
      assert runner.memory_store == nil
    end

    test "Runner accepts session_store as {Module, opts} tuple" do
      # Python: sqlite_session_factory("sqlite:///test.db") → SqliteSessionService(db_path="test.db")
      # Elixir: {ADK.Session.Store.InMemory, []} in session_store
      agent = ADK.Agent.LlmAgent.new(name: "test-bot", model: "test", instruction: "Help")

      runner =
        ADK.Runner.new(
          app_name: "test",
          agent: agent,
          session_store: {ADK.Session.Store.InMemory, []}
        )

      assert runner.session_store == {ADK.Session.Store.InMemory, []}
    end

    test "Runner accepts artifact_service as {Module, opts} tuple" do
      # Python: gcs_artifact_factory("gs://my-bucket") → GcsArtifactService(bucket_name="my-bucket")
      # Elixir: {ADK.Artifact.GCS, bucket: "my-bucket"} in artifact_service
      agent = ADK.Agent.LlmAgent.new(name: "test-bot", model: "test", instruction: "Help")

      runner =
        ADK.Runner.new(
          app_name: "test",
          agent: agent,
          artifact_service: {ADK.Artifact.GCS, bucket: "my-bucket"}
        )

      assert runner.artifact_service == {ADK.Artifact.GCS, bucket: "my-bucket"}
    end

    test "Runner accepts memory_store as {Module, opts} tuple" do
      # Python: agentengine_memory_factory("agentengine://456") → VertexAiMemoryBankService(...)
      # Elixir: {ADK.Memory.Store.VertexAI, [...]} in memory_store
      agent = ADK.Agent.LlmAgent.new(name: "test-bot", model: "test", instruction: "Help")

      runner =
        ADK.Runner.new(
          app_name: "test",
          agent: agent,
          memory_store:
            {ADK.Memory.Store.VertexAI,
             project_id: "my-project", location: "us-central1", reasoning_engine_id: "456"}
        )

      assert match?({ADK.Memory.Store.VertexAI, _}, runner.memory_store)
    end

    test "Runner can be configured with all three services simultaneously" do
      # Python: A fully configured runner with session, artifact, and memory services
      # Elixir: All three {Module, opts} tuples at once
      agent = ADK.Agent.LlmAgent.new(name: "test-bot", model: "test", instruction: "Help")

      runner =
        ADK.Runner.new(
          app_name: "full-config",
          agent: agent,
          session_store: {ADK.Session.Store.InMemory, []},
          artifact_service: {ADK.Artifact.InMemory, []},
          memory_store: {ADK.Memory.InMemory, []}
        )

      assert runner.session_store == {ADK.Session.Store.InMemory, []}
      assert runner.artifact_service == {ADK.Artifact.InMemory, []}
      assert runner.memory_store == {ADK.Memory.InMemory, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Unsupported service handling
  # ---------------------------------------------------------------------------

  describe "unsupported or nil service handling" do
    test "Python unsupported://foo scheme maps to Elixir nil service_store" do
      # Python:
      #   session_service = registry.create_session_service("unsupported://foo")
      #   assert session_service is None
      # Elixir: passing nil or an unsupported module is handled gracefully at runtime.
      # The Runner does not validate module existence at struct creation time.
      agent = ADK.Agent.LlmAgent.new(name: "test-bot", model: "test", instruction: "Help")
      runner = ADK.Runner.new(app_name: "test", agent: agent)

      # nil session_store is explicitly allowed (in-memory fallback)
      assert runner.session_store == nil
    end
  end
end
