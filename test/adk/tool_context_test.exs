defmodule ADK.ToolContextTest do
  use ExUnit.Case, async: true

  alias ADK.ToolContext
  alias ADK.Auth.Config, as: AuthConfig
  alias ADK.Auth.Credential

  setup do
    {:ok, session_pid} =
      ADK.Session.start_link(
        app_name: "test",
        user_id: "user1",
        session_id: "tool-ctx-#{System.unique_integer([:positive])}",
        name: nil
      )

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      session_pid: session_pid,
      agent: nil,
      callbacks: [],
      policies: []
    }

    tool = %{name: "test_tool"}
    tool_ctx = ToolContext.new(ctx, "call-1", tool)

    on_exit(fn -> Process.alive?(session_pid) && GenServer.stop(session_pid) end)

    %{tool_ctx: tool_ctx, ctx: ctx, session_pid: session_pid}
  end

  # ===========================================================================
  # Session State
  # ===========================================================================

  describe "session state read/write" do
    test "get_state returns default when key doesn't exist", %{tool_ctx: tc} do
      assert ToolContext.get_state(tc, "missing") == nil
      assert ToolContext.get_state(tc, "missing", "default") == "default"
    end

    test "put_state and get_state roundtrip", %{tool_ctx: tc} do
      assert {:ok, tc} = ToolContext.put_state(tc, "key1", "value1")
      assert ToolContext.get_state(tc, "key1") == "value1"
    end

    test "put_state tracks state delta", %{tool_ctx: tc} do
      {:ok, tc} = ToolContext.put_state(tc, "key1", "value1")
      {:ok, tc} = ToolContext.put_state(tc, "key2", "value2")
      actions = ToolContext.actions(tc)
      assert actions.state_delta == %{"key1" => "value1", "key2" => "value2"}
    end

    test "put_state returns error when no session" do
      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: nil, callbacks: [], policies: []}
      tc = ToolContext.new(ctx, "call-1", %{name: "test"})
      assert {:error, :no_session} = ToolContext.put_state(tc, "key", "val")
    end
  end

  # ===========================================================================
  # Artifacts
  # ===========================================================================

  describe "artifacts without service" do
    test "save_artifact returns error without service", %{tool_ctx: tc} do
      assert {:error, :no_artifact_service} =
               ToolContext.save_artifact(tc, "file.txt", %{data: "hello", content_type: "text/plain", metadata: %{}})
    end

    test "load_artifact returns error without service", %{tool_ctx: tc} do
      assert {:error, :no_artifact_service} = ToolContext.load_artifact(tc, "file.txt")
    end

    test "list_artifacts returns error without service", %{tool_ctx: tc} do
      assert {:error, :no_artifact_service} = ToolContext.list_artifacts(tc)
    end
  end

  describe "artifacts with mock service" do
    setup %{ctx: ctx} do
      # Use an Agent process as a mock artifact store
      {:ok, store_pid} = Agent.start_link(fn -> %{} end)

      mock_module = create_artifact_mock(store_pid)

      ctx = %{ctx | artifact_service: mock_module, app_name: "test", user_id: "user1"}
      tc = ToolContext.new(ctx, "call-1", %{name: "test_tool"})

      on_exit(fn -> Process.alive?(store_pid) && Agent.stop(store_pid) end)

      %{tool_ctx: tc, store_pid: store_pid}
    end

    test "save and load artifact roundtrip", %{tool_ctx: tc} do
      artifact = %{data: "hello world", content_type: "text/plain", metadata: %{}}
      assert {:ok, 1, tc} = ToolContext.save_artifact(tc, "greeting.txt", artifact)

      # Check artifact delta was tracked
      assert ToolContext.actions(tc).artifact_delta == %{"greeting.txt" => 1}

      # Load it back
      assert {:ok, ^artifact} = ToolContext.load_artifact(tc, "greeting.txt")
    end

    test "list_artifacts returns filenames", %{tool_ctx: tc} do
      artifact = %{data: "x", content_type: "text/plain", metadata: %{}}
      {:ok, _, tc} = ToolContext.save_artifact(tc, "a.txt", artifact)
      {:ok, _, _tc} = ToolContext.save_artifact(tc, "b.txt", artifact)

      {:ok, files} = ToolContext.list_artifacts(tc)
      assert Enum.sort(files) == ["a.txt", "b.txt"]
    end
  end

  # ===========================================================================
  # Credentials
  # ===========================================================================

  describe "credentials without service" do
    test "load_credential returns error without service", %{tool_ctx: tc} do
      assert {:error, :no_credential_service} = ToolContext.load_credential(tc, "api_key")
    end

    test "save_credential returns error without service", %{tool_ctx: tc} do
      cred = Credential.api_key("secret")
      assert {:error, :no_credential_service} = ToolContext.save_credential(tc, "api_key", cred)
    end

    test "has_credential? returns false without service", %{tool_ctx: tc} do
      refute ToolContext.has_credential?(tc, "api_key")
    end
  end

  describe "request_credential" do
    test "records auth config in event actions", %{tool_ctx: tc} do
      auth_config = AuthConfig.new(credential_type: :oauth2, scopes: ["read"])
      assert {:ok, tc} = ToolContext.request_credential(tc, auth_config)
      assert Map.has_key?(ToolContext.actions(tc).requested_auth_configs, "call-1")
    end

    test "fails without function_call_id", %{ctx: ctx} do
      tc = ToolContext.new(ctx, nil, %{name: "test"})
      auth_config = AuthConfig.new(credential_type: :api_key)
      assert {:error, :no_function_call_id} = ToolContext.request_credential(tc, auth_config)
    end
  end

  describe "credentials with mock service" do
    setup %{ctx: ctx} do
      {:ok, store_pid} = Agent.start_link(fn -> %{} end)

      mock_module = create_credential_mock(store_pid)

      ctx = %{ctx | credential_service: mock_module}
      tc = ToolContext.new(ctx, "call-1", %{name: "test_tool"})

      on_exit(fn -> Process.alive?(store_pid) && Agent.stop(store_pid) end)

      %{tool_ctx: tc, store_pid: store_pid}
    end

    test "save and load credential roundtrip", %{tool_ctx: tc} do
      cred = Credential.api_key("my-secret")
      assert :ok = ToolContext.save_credential(tc, "github", cred)
      assert {:ok, ^cred} = ToolContext.load_credential(tc, "github")
      assert ToolContext.has_credential?(tc, "github")
    end

    test "load missing credential returns not_found", %{tool_ctx: tc} do
      assert :not_found = ToolContext.load_credential(tc, "nonexistent")
      refute ToolContext.has_credential?(tc, "nonexistent")
    end
  end

  # ===========================================================================
  # Agent Transfer
  # ===========================================================================

  describe "agent transfer" do
    test "transfer_to_agent returns event with transfer action", %{tool_ctx: tc} do
      event = ToolContext.transfer_to_agent(tc, "specialist_agent")
      assert event.actions.transfer_to_agent == "specialist_agent"
      assert ADK.Event.text(event) =~ "specialist_agent"
    end
  end

  # ===========================================================================
  # Event Actions
  # ===========================================================================

  describe "actions/1" do
    test "returns initial empty actions", %{tool_ctx: tc} do
      actions = ToolContext.actions(tc)
      assert actions.state_delta == %{}
      assert actions.artifact_delta == %{}
      assert actions.requested_auth_configs == %{}
      assert actions.transfer_to_agent == nil
    end
  end

  # ===========================================================================
  # Legacy API
  # ===========================================================================

  describe "legacy backward compatibility" do
    test "get_artifact delegates to load_artifact", %{tool_ctx: tc} do
      assert {:error, :no_artifact_service} = ToolContext.get_artifact(tc, "file")
    end

    test "set_artifact delegates to save_artifact", %{tool_ctx: tc} do
      assert {:error, :no_artifact_service} = ToolContext.set_artifact(tc, "file", "data")
    end

    test "get_credential delegates to load_credential", %{tool_ctx: tc} do
      assert {:error, :no_credential_service} = ToolContext.get_credential(tc, "key")
    end
  end

  # ===========================================================================
  # Mock Helpers
  # ===========================================================================

  defp create_artifact_mock(store_pid) do
    # We create a module dynamically for the mock
    mod_name = :"ADK.Test.ArtifactMock_#{System.unique_integer([:positive])}"

    Module.create(
      mod_name,
      quote do
        @behaviour ADK.Artifact.Store
        @store_pid unquote(store_pid)

        @impl true
        def save(_app, _user, session_id, filename, artifact, _opts) do
          key = {session_id, filename}
          version = Agent.get_and_update(@store_pid, fn state ->
            v = Map.get(state, {:version, key}, 0) + 1
            {v, state |> Map.put(key, artifact) |> Map.put({:version, key}, v)}
          end)
          {:ok, version}
        end

        @impl true
        def load(_app, _user, session_id, filename, _opts) do
          key = {session_id, filename}
          case Agent.get(@store_pid, &Map.get(&1, key)) do
            nil -> :not_found
            artifact -> {:ok, artifact}
          end
        end

        @impl true
        def list(_app, _user, session_id, _opts) do
          files = Agent.get(@store_pid, fn state ->
            state
            |> Enum.filter(fn
              {{^session_id, _name}, _val} -> true
              _ -> false
            end)
            |> Enum.map(fn {{_, name}, _} -> name end)
            |> Enum.uniq()
          end)
          {:ok, files}
        end

        @impl true
        def delete(_app, _user, session_id, filename, _opts) do
          Agent.update(@store_pid, &Map.delete(&1, {session_id, filename}))
          :ok
        end
      end,
      Macro.Env.location(__ENV__)
    )

    mod_name
  end

  defp create_credential_mock(store_pid) do
    mod_name = :"ADK.Test.CredentialMock_#{System.unique_integer([:positive])}"

    Module.create(
      mod_name,
      quote do
        @behaviour ADK.Auth.CredentialStore
        @store_pid unquote(store_pid)

        @impl true
        def get(name, _opts) do
          case Agent.get(@store_pid, &Map.get(&1, name)) do
            nil -> :not_found
            cred -> {:ok, cred}
          end
        end

        @impl true
        def put(name, credential, _opts) do
          Agent.update(@store_pid, &Map.put(&1, name, credential))
          :ok
        end

        @impl true
        def delete(name, _opts) do
          Agent.update(@store_pid, &Map.delete(&1, name))
          :ok
        end
      end,
      Macro.Env.location(__ENV__)
    )

    mod_name
  end
end
