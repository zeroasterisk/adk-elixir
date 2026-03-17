defmodule ADK.CallbackContextTest do
  use ExUnit.Case, async: true

  alias ADK.CallbackContext
  alias ADK.ToolContext
  alias ADK.Auth.AuthConfig
  alias ADK.Auth.Credential
  alias ADK.Memory.MemoryEntry
  alias Google.GenAI.V1.Content
  alias ADK.Error.ValueError

  @app_name "test-app"
  @user_id "test-user"
  @session_id "test-session-id"

  defp mock_invocation_context(artifact_service, credential_service, memory_service) do
    {:ok, pid} = Agent.start_link(fn -> %ADK.Session{
        id: @session_id,
        app_name: @app_name,
        user_id: @user_id,
        state: %{"key1" => "value1", "key2" => "value2"}
      } end)
    %ADK.Context{
      invocation_id: "test-invocation-id",
      agent: %{name: "test-agent-name"},
      session_pid: pid,
      app_name: @app_name,
      user_id: @user_id,
      artifact_service: artifact_service,
      credential_service: credential_service,
      memory_store: memory_service
    }
  end

  defmodule MockArtifactService do
    @behaviour ADK.Artifact.Store
    def list_artifact_keys(_app_name, _user_id, _session_id), do: {:ok, ["file1.txt", "file2.txt", "file3.txt"]}
    def save_artifact(_, _, _, _, _, _), do: {:ok, 1}
    def load_artifact(_, _, _, _, _), do: {:ok, %{text: "test content"}}
  end

  defmodule MockCredentialService do
    @behaviour ADK.Auth.CredentialStore
    def save_credential(_cred, _ctx), do: :ok
    def load_credential(_cfg, _ctx), do: {:ok, %Credential{type: :oauth2}}
  end

  defmodule MockMemoryService do
    @behaviour ADK.Memory.Store
    def add_session_to_memory(_session), do: :ok
    def add_events_to_memory(_app_name, _user_id, _session_id, _events, _custom_metadata), do: :ok
    def add_memory(_app_name, _user_id, _memories, _custom_metadata), do: :ok
  end

  describe "list_artifacts" do
    test "returns artifact keys when service is available" do
      invocation_context = mock_invocation_context(MockArtifactService, nil, nil)
      context = CallbackContext.new(invocation_context)
      assert {:ok, ["file1.txt", "file2.txt", "file3.txt"]} == CallbackContext.list_artifacts(context)
    end

    test "returns value error when service is nil" do
      invocation_context = mock_invocation_context(nil, nil, nil)
      context = CallbackContext.new(invocation_context)
      assert {:error, %ValueError{message: "Artifact service is not initialized."}} == CallbackContext.list_artifacts(context)
    end

    test "ToolContext inherits list_artifacts" do
      invocation_context = mock_invocation_context(MockArtifactService, nil, nil)
      tool_context = ToolContext.new(invocation_context)
      assert {:ok, ["file1.txt", "file2.txt", "file3.txt"]} == ToolContext.list_artifacts(tool_context)
    end

    test "ToolContext list_artifacts raises value error when service is nil" do
      invocation_context = mock_invocation_context(nil, nil, nil)
      tool_context = ToolContext.new(invocation_context)
      assert {:error, %ValueError{message: "Artifact service is not initialized."}} == ToolContext.list_artifacts(tool_context)
    end
  end

  describe "credentials" do
    test "save_credential with service" do
      invocation_context = mock_invocation_context(nil, MockCredentialService, nil)
      context = CallbackContext.new(invocation_context)
      assert :ok == CallbackContext.save_credential(context, %AuthConfig{})
    end

    test "save_credential without service" do
      invocation_context = mock_invocation_context(nil, nil, nil)
      context = CallbackContext.new(invocation_context)
      assert {:error, %ValueError{message: "Credential service is not initialized"}} == CallbackContext.save_credential(context, %AuthConfig{})
    end

    test "load_credential with service" do
      invocation_context = mock_invocation_context(nil, MockCredentialService, nil)
      context = CallbackContext.new(invocation_context)
      assert {:ok, %Credential{type: :oauth2}} == CallbackContext.load_credential(context, %AuthConfig{})
    end

    test "load_credential without service" do
      invocation_context = mock_invocation_context(nil, nil, nil)
      context = CallbackContext.new(invocation_context)
      assert {:error, %ValueError{message: "Credential service is not initialized"}} == CallbackContext.load_credential(context, %AuthConfig{})
    end
  end

  describe "artifacts" do
    test "save_artifact with service" do
      invocation_context = mock_invocation_context(MockArtifactService, nil, nil)
      context = CallbackContext.new(invocation_context)
      test_artifact = %{text: "test content"}
      assert {:ok, 1} == CallbackContext.save_artifact(context, "test_file.txt", test_artifact)
    end

    test "load_artifact with service" do
      invocation_context = mock_invocation_context(MockArtifactService, nil, nil)
      context = CallbackContext.new(invocation_context)
      assert {:ok, %{text: "test content"}} == CallbackContext.load_artifact(context, "test_file.txt")
    end
  end

  describe "memory" do
    test "add_session_to_memory with service" do
      invocation_context = mock_invocation_context(nil, nil, MockMemoryService)
      context = CallbackContext.new(invocation_context)
      assert :ok == CallbackContext.add_session_to_memory(context)
    end

    test "add_session_to_memory without service" do
      invocation_context = mock_invocation_context(nil, nil, nil)
      context = CallbackContext.new(invocation_context)
      assert {:error, %ValueError{message: "Cannot add session to memory: memory service is not available."}} == CallbackContext.add_session_to_memory(context)
    end

    test "add_events_to_memory with service" do
      invocation_context = mock_invocation_context(nil, nil, MockMemoryService)
      context = CallbackContext.new(invocation_context)
      test_event = %{}
      assert :ok == CallbackContext.add_events_to_memory(context, [test_event], %{ttl: "6000s"})
    end

    test "add_events_to_memory without service" do
      invocation_context = mock_invocation_context(nil, nil, nil)
      context = CallbackContext.new(invocation_context)
      assert {:error, %ValueError{message: "Cannot add events to memory: memory service is not available."}} == CallbackContext.add_events_to_memory(context, [%{}])
    end

    test "add_memory with service" do
      invocation_context = mock_invocation_context(nil, nil, MockMemoryService)
      context = CallbackContext.new(invocation_context)
      memories = [%MemoryEntry{content: %Content{parts: [%{text: "fact one"}]}}]
      metadata = %{ttl: "6000s"}
      assert :ok == CallbackContext.add_memory(context, memories, metadata)
    end

    test "add_memory without service" do
      invocation_context = mock_invocation_context(nil, nil, nil)
      context = CallbackContext.new(invocation_context)
      memories = [%MemoryEntry{content: %Content{parts: [%{text: "fact one"}]}}]
      assert {:error, %ValueError{message: "Cannot add memory: memory service is not available."}} == CallbackContext.add_memory(context, memories)
    end
  end

  describe "ToolContext memory" do
    test "add_session_to_memory with service" do
      invocation_context = mock_invocation_context(nil, nil, MockMemoryService)
      context = ToolContext.new(invocation_context)
      assert :ok == ToolContext.add_session_to_memory(context)
    end

    test "add_session_to_memory without service" do
      invocation_context = mock_invocation_context(nil, nil, nil)
      context = ToolContext.new(invocation_context)
      assert {:error, %ValueError{message: "Cannot add session to memory: memory service is not available."}} == ToolContext.add_session_to_memory(context)
    end
  end
end


