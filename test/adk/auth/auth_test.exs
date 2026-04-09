defmodule ADK.Auth.CredentialTest do
  use ExUnit.Case, async: true

  alias ADK.Auth.Credential

  describe "credential constructors" do
    test "api_key creates correct struct" do
      cred = Credential.api_key("sk-123")
      assert cred.type == :api_key
      assert cred.api_key == "sk-123"
      assert cred.access_token == nil
    end

    test "oauth2 creates correct struct with options" do
      cred =
        Credential.oauth2("tok-123",
          refresh_token: "ref-456",
          client_id: "client1",
          client_secret: "secret1",
          scopes: ["read", "write"],
          token_endpoint: "https://auth.example.com/token"
        )

      assert cred.type == :oauth2
      assert cred.access_token == "tok-123"
      assert cred.refresh_token == "ref-456"
      assert cred.client_id == "client1"
      assert cred.client_secret == "secret1"
      assert cred.scopes == ["read", "write"]
      assert cred.token_endpoint == "https://auth.example.com/token"
    end

    test "http_bearer creates correct struct" do
      cred = Credential.http_bearer("bearer-tok")
      assert cred.type == :http_bearer
      assert cred.access_token == "bearer-tok"
    end

    test "service_account creates correct struct" do
      key = %{"project_id" => "proj-1", "private_key" => "..."}
      cred = Credential.service_account(key, scopes: ["cloud-platform"])
      assert cred.type == :service_account
      assert cred.service_account_key == key
      assert cred.scopes == ["cloud-platform"]
    end

    test "open_id_connect creates correct struct" do
      cred = Credential.open_id_connect("oidc-tok", client_id: "c1")
      assert cred.type == :open_id_connect
      assert cred.access_token == "oidc-tok"
      assert cred.client_id == "c1"
    end

    test "metadata can be attached to any credential" do
      cred = Credential.api_key("key", metadata: %{source: "vault"})
      assert cred.metadata == %{source: "vault"}
    end
  end
end

defmodule ADK.Auth.InMemoryStoreTest do
  use ExUnit.Case, async: true

  alias ADK.Auth.{Credential, InMemoryStore}

  setup do
    {:ok, pid} = InMemoryStore.start_link()
    %{store: pid}
  end

  test "put and get credential", %{store: store} do
    cred = Credential.api_key("sk-test")
    :ok = InMemoryStore.put("my_service", cred, server: store)
    assert {:ok, ^cred} = InMemoryStore.get("my_service", server: store)
  end

  test "get returns :not_found for missing credential", %{store: store} do
    assert :not_found = InMemoryStore.get("nonexistent", server: store)
  end

  test "delete removes credential", %{store: store} do
    cred = Credential.api_key("sk-test")
    :ok = InMemoryStore.put("svc", cred, server: store)
    :ok = InMemoryStore.delete("svc", server: store)
    assert :not_found = InMemoryStore.get("svc", server: store)
  end

  test "overwrite existing credential", %{store: store} do
    cred1 = Credential.api_key("old-key")
    cred2 = Credential.api_key("new-key")
    :ok = InMemoryStore.put("svc", cred1, server: store)
    :ok = InMemoryStore.put("svc", cred2, server: store)
    assert {:ok, ^cred2} = InMemoryStore.get("svc", server: store)
  end
end

defmodule ADK.Auth.ConfigTest do
  use ExUnit.Case, async: true

  alias ADK.Auth.Config

  test "new creates config with defaults" do
    config = Config.new(credential_type: :api_key)
    assert config.credential_type == :api_key
    assert config.required == true
    assert config.scopes == []
  end

  test "new with all options" do
    config =
      Config.new(
        credential_type: :oauth2,
        required: false,
        scopes: ["read"],
        provider: "github",
        credential_name: "github_token"
      )

    assert config.credential_type == :oauth2
    assert config.required == false
    assert config.provider == "github"
    assert config.credential_name == "github_token"
  end
end

defmodule ADK.Auth.ToolContextIntegrationTest do
  use ExUnit.Case, async: true

  alias ADK.Auth.{Credential, InMemoryStore}

  setup do
    store_name = :"Agent_#{System.unique_integer([:positive])}"
    {:ok, store} = InMemoryStore.start_link(name: store_name)

    # Create a wrapper module that passes the store pid to InMemoryStore
    wrapper = create_credential_wrapper(store_name)

    %{store: store, credential_service: wrapper}
  end

  test "load_credential retrieves from store via tool context", %{credential_service: service} do
    cred = Credential.api_key("sk-tool")
    :ok = service.put("my_tool", cred, [])

    tool =
      ADK.Tool.FunctionTool.new(:my_tool,
        description: "A tool",
        func: fn _ctx, _args -> {:ok, "done"} end,
        parameters: %{}
      )

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      session_pid: nil,
      agent: nil,
      credential_service: service
    }

    tool_ctx = ADK.ToolContext.new(ctx, "fc-1", tool)

    assert {:ok, ^cred} = ADK.ToolContext.load_credential(tool_ctx, "my_tool")
  end

  test "save_credential and load_credential roundtrip", %{credential_service: service} do
    cred = Credential.oauth2("tok-123")

    tool =
      ADK.Tool.FunctionTool.new(:my_tool,
        description: "A tool",
        func: fn _ctx, _args -> {:ok, "done"} end,
        parameters: %{}
      )

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      session_pid: nil,
      agent: nil,
      credential_service: service
    }

    tool_ctx = ADK.ToolContext.new(ctx, "fc-1", tool)

    assert :ok = ADK.ToolContext.save_credential(tool_ctx, "custom_name", cred)
    assert {:ok, ^cred} = ADK.ToolContext.load_credential(tool_ctx, "custom_name")
  end

  test "request_credential records auth config in actions" do
    tool =
      ADK.Tool.FunctionTool.new(:test_tool,
        description: "Test",
        func: fn _ctx, _args -> {:ok, "ok"} end,
        parameters: %{}
      )

    ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: nil}
    tool_ctx = ADK.ToolContext.new(ctx, "fc-1", tool)

    auth_config = ADK.Auth.Config.new(credential_type: :oauth2, scopes: ["read"])
    assert {:ok, updated_tc} = ADK.ToolContext.request_credential(tool_ctx, auth_config)
    assert Map.has_key?(ADK.ToolContext.actions(updated_tc).requested_auth_configs, "fc-1")
  end

  test "load_credential returns error without service" do
    tool =
      ADK.Tool.FunctionTool.new(:test_tool,
        description: "Test",
        func: fn _ctx, _args -> {:ok, "ok"} end,
        parameters: %{}
      )

    ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: nil}
    tool_ctx = ADK.ToolContext.new(ctx, "fc-1", tool)

    assert {:error, :no_credential_service} = ADK.ToolContext.load_credential(tool_ctx, "api_key")
  end

  defp create_credential_wrapper(store_name) do
    mod_name = :"ADK.Test.CredentialWrapper_#{System.unique_integer([:positive])}"

    Module.create(
      mod_name,
      quote do
        @behaviour ADK.Auth.CredentialStore
        @store_name unquote(store_name)

        @impl true
        def get(name, _opts), do: ADK.Auth.InMemoryStore.get(name, server: @store_name)

        @impl true
        def put(name, cred, _opts), do: ADK.Auth.InMemoryStore.put(name, cred, server: @store_name)

        @impl true
        def delete(name, _opts), do: ADK.Auth.InMemoryStore.delete(name, server: @store_name)
      end,
      Macro.Env.location(__ENV__)
    )

    mod_name
  end
end
