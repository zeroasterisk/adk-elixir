defmodule ADK.Agent.ContextTest do
  @moduledoc """
  Parity tests for Python ADK's test_context.py.

  Maps Python `Context` → Elixir `ADK.ToolContext` (tool-facing context),
  and Python `InvocationContext` → Elixir `ADK.Context` (invocation struct).

  Skipped groups (not yet in Elixir):
  - TestContextMemoryMethods
  - TestContextAddUiWidget
  """
  use ExUnit.Case, async: true

  alias ADK.ToolContext
  alias ADK.Context
  alias ADK.EventActions

  # ---------------------------------------------------------------------------
  # Mock Artifact Service
  # ---------------------------------------------------------------------------

  defmodule MockArtifactService do
    @moduledoc false

    def save(_app, _user, _session, filename, artifact, _opts) do
      # Store in process dict so tests can verify what was saved
      Process.put({:saved_artifact, filename}, artifact)
      {:ok, 1}
    end

    def load(_app, _user, _session, filename, opts) do
      version = Keyword.get(opts, :version, nil)
      Process.put({:loaded_artifact, filename}, version)
      {:ok, %{data: "test content", filename: filename, version: version || 1}}
    end

    def list(_app, _user, _session, _opts) do
      {:ok, ["file1.txt", "file2.txt", "file3.txt"]}
    end
  end

  # ---------------------------------------------------------------------------
  # Mock Credential Service
  # ---------------------------------------------------------------------------

  defmodule MockCredentialService do
    @moduledoc false

    def get(name, _opts) do
      case Process.get({:credential, name}) do
        nil -> :not_found
        cred -> {:ok, cred}
      end
    end

    def put(name, credential, _opts) do
      Process.put({:credential, name}, credential)
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_ctx(opts \\ []) do
    %Context{
      invocation_id: "test-invocation-id",
      app_name: Keyword.get(opts, :app_name, "test-app"),
      user_id: Keyword.get(opts, :user_id, "test-user"),
      artifact_service: Keyword.get(opts, :artifact_service, nil),
      credential_service: Keyword.get(opts, :credential_service, nil),
      session_pid: Keyword.get(opts, :session_pid, nil)
    }
  end

  defp tool_ctx(opts \\ []) do
    ctx = base_ctx(opts)

    %ToolContext{
      context: ctx,
      function_call_id: Keyword.get(opts, :function_call_id, nil),
      tool_name: Keyword.get(opts, :tool_name, "test-tool"),
      actions: %EventActions{}
    }
  end

  # =========================================================================
  # TestContextInitialization
  # =========================================================================

  describe "initialization" do
    test "without function_call_id" do
      tc = tool_ctx()

      assert tc.context.invocation_id == "test-invocation-id"
      assert %EventActions{} = tc.actions
      assert tc.function_call_id == nil
    end

    test "with function_call_id" do
      tc = tool_ctx(function_call_id: "test-function-call-id")

      assert tc.function_call_id == "test-function-call-id"
    end

    test "actions property returns EventActions struct" do
      tc = tool_ctx()

      assert %EventActions{} = ToolContext.actions(tc)
      assert ToolContext.actions(tc) == tc.actions
    end

    test "default actions have empty deltas" do
      tc = tool_ctx()

      assert tc.actions.state_delta == %{}
      assert tc.actions.artifact_delta == %{}
      assert tc.actions.requested_auth_configs == %{}
      assert tc.actions.transfer_to_agent == nil
    end

    test "new/3 creates tool context from invocation context" do
      ctx = base_ctx()
      tool_def = %{name: "my-tool"}
      tc = ToolContext.new(ctx, "call-123", tool_def)

      assert tc.context == ctx
      assert tc.function_call_id == "call-123"
      assert tc.tool_name == "my-tool"
      assert %EventActions{} = tc.actions
    end
  end

  # =========================================================================
  # TestContextListArtifacts
  # =========================================================================

  describe "list_artifacts" do
    test "returns artifact keys from service" do
      tc = tool_ctx(artifact_service: MockArtifactService)

      assert {:ok, keys} = ToolContext.list_artifacts(tc)
      assert keys == ["file1.txt", "file2.txt", "file3.txt"]
    end

    test "returns error when no artifact service" do
      tc = tool_ctx(artifact_service: nil)

      assert {:error, :no_artifact_service} = ToolContext.list_artifacts(tc)
    end

    test "works with {module, opts} tuple service config" do
      tc = tool_ctx(artifact_service: {MockArtifactService, []})

      assert {:ok, keys} = ToolContext.list_artifacts(tc)
      assert keys == ["file1.txt", "file2.txt", "file3.txt"]
    end
  end

  # =========================================================================
  # TestContextSaveLoadArtifact
  # =========================================================================

  describe "save_artifact" do
    test "saves artifact and returns version" do
      tc = tool_ctx(artifact_service: MockArtifactService)
      artifact = %{data: "test content", content_type: "text/plain", metadata: %{}}

      assert {:ok, version, updated_tc} =
               ToolContext.save_artifact(tc, "test_file.txt", artifact)

      assert version == 1
      assert updated_tc.actions.artifact_delta["test_file.txt"] == 1
    end

    test "save_artifact returns error when no service" do
      tc = tool_ctx(artifact_service: nil)
      artifact = %{data: "test content"}

      assert {:error, :no_artifact_service} =
               ToolContext.save_artifact(tc, "test_file.txt", artifact)
    end

    test "multiple saves update artifact_delta" do
      tc = tool_ctx(artifact_service: MockArtifactService)

      {:ok, _v1, tc2} =
        ToolContext.save_artifact(tc, "file_a.txt", %{data: "a"})

      {:ok, _v2, tc3} =
        ToolContext.save_artifact(tc2, "file_b.txt", %{data: "b"})

      assert tc3.actions.artifact_delta["file_a.txt"] == 1
      assert tc3.actions.artifact_delta["file_b.txt"] == 1
    end
  end

  describe "load_artifact" do
    test "loads artifact by filename" do
      tc = tool_ctx(artifact_service: MockArtifactService)

      assert {:ok, artifact} = ToolContext.load_artifact(tc, "test_file.txt")
      assert artifact.data == "test content"
      assert artifact.filename == "test_file.txt"
    end

    test "loads artifact with specific version" do
      tc = tool_ctx(artifact_service: MockArtifactService)

      assert {:ok, artifact} =
               ToolContext.load_artifact(tc, "test_file.txt", version: 2)

      assert artifact.version == 2
    end

    test "load_artifact returns error when no service" do
      tc = tool_ctx(artifact_service: nil)

      assert {:error, :no_artifact_service} =
               ToolContext.load_artifact(tc, "test_file.txt")
    end
  end

  # =========================================================================
  # TestContextCredentialMethods
  # =========================================================================

  describe "save_credential" do
    test "saves credential with service" do
      tc = tool_ctx(credential_service: MockCredentialService)
      credential = %{type: :oauth2, token: "abc123"}

      assert :ok = ToolContext.save_credential(tc, "github_token", credential)
    end

    test "save_credential returns error when no service" do
      tc = tool_ctx(credential_service: nil)

      assert {:error, :no_credential_service} =
               ToolContext.save_credential(tc, "github_token", %{token: "abc"})
    end
  end

  describe "load_credential" do
    test "loads credential with service" do
      tc = tool_ctx(credential_service: MockCredentialService)
      credential = %{type: :oauth2, token: "abc123"}

      # Pre-store the credential
      MockCredentialService.put("github_token", credential, [])

      assert {:ok, loaded} = ToolContext.load_credential(tc, "github_token")
      assert loaded == credential
    end

    test "load_credential returns not_found for missing credential" do
      tc = tool_ctx(credential_service: MockCredentialService)

      assert :not_found = ToolContext.load_credential(tc, "nonexistent")
    end

    test "load_credential returns error when no service" do
      tc = tool_ctx(credential_service: nil)

      assert {:error, :no_credential_service} =
               ToolContext.load_credential(tc, "github_token")
    end
  end

  describe "has_credential?" do
    test "returns true when credential exists" do
      tc = tool_ctx(credential_service: MockCredentialService)
      MockCredentialService.put("my_cred", %{token: "x"}, [])

      assert ToolContext.has_credential?(tc, "my_cred")
    end

    test "returns false when credential missing" do
      tc = tool_ctx(credential_service: MockCredentialService)

      refute ToolContext.has_credential?(tc, "missing_cred")
    end

    test "returns false when no service" do
      tc = tool_ctx(credential_service: nil)

      refute ToolContext.has_credential?(tc, "any_cred")
    end
  end

  # =========================================================================
  # TestContextRequestCredential
  # =========================================================================

  describe "request_credential" do
    test "with function_call_id records auth config in actions" do
      tc = tool_ctx(function_call_id: "test-function-call-id")
      auth_config = %{type: :oauth2, provider: "github", scopes: ["repo"]}

      assert {:ok, updated_tc} = ToolContext.request_credential(tc, auth_config)

      assert updated_tc.actions.requested_auth_configs["test-function-call-id"] ==
               auth_config
    end

    test "without function_call_id returns error" do
      tc = tool_ctx(function_call_id: nil)
      auth_config = %{type: :oauth2, provider: "github"}

      assert {:error, :no_function_call_id} =
               ToolContext.request_credential(tc, auth_config)
    end

    test "multiple request_credentials accumulate in actions" do
      tc = tool_ctx(function_call_id: "call-1")
      config_1 = %{provider: "github"}

      {:ok, tc2} = ToolContext.request_credential(tc, config_1)

      # Simulate a second call with different function_call_id
      tc3 = %{tc2 | function_call_id: "call-2"}
      config_2 = %{provider: "google"}
      {:ok, tc4} = ToolContext.request_credential(tc3, config_2)

      assert tc4.actions.requested_auth_configs["call-1"] == config_1
      assert tc4.actions.requested_auth_configs["call-2"] == config_2
    end
  end

  # =========================================================================
  # TestContextTransferToAgent
  # =========================================================================

  describe "transfer_to_agent" do
    test "returns event with transfer action" do
      tc = tool_ctx(function_call_id: "call-1")

      event = ToolContext.transfer_to_agent(tc, "weather_agent")

      assert event.actions.transfer_to_agent == "weather_agent"
    end
  end

  # =========================================================================
  # EventActions struct tests
  # =========================================================================

  describe "EventActions struct" do
    test "defaults are empty/false" do
      actions = %EventActions{}

      assert actions.state_delta == %{}
      assert actions.artifact_delta == %{}
      assert actions.requested_auth_configs == %{}
      assert actions.transfer_to_agent == nil
      assert actions.escalate == false
      assert actions.skip_summarization == false
      assert actions.end_of_agent == false
    end

    test "can set transfer_to_agent" do
      actions = %EventActions{transfer_to_agent: "target"}
      assert actions.transfer_to_agent == "target"
    end

    test "can set escalate" do
      actions = %EventActions{escalate: true}
      assert actions.escalate == true
    end
  end
end
