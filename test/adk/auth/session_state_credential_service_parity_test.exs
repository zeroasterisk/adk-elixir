defmodule ADK.Auth.SessionStateCredentialServiceParityTest do
  @moduledoc """
  Parity tests for Python ADK's `test_session_state_credential_service.py`.

  The Python `SessionStateCredentialService` stores credentials in
  `callback_context.state[credential_key]`. In Elixir, the equivalent
  session-scoped storage is `ADK.Auth.InMemoryStore` — each Agent
  process acts as an isolated session state store.
  """
  use ExUnit.Case, async: true

  alias ADK.Auth.{Credential, InMemoryStore}

  # -- Helpers ---------------------------------------------------------------

  defp oauth2_cred(client_id, client_secret, opts \\ []) do
    Credential.oauth2(nil,
      client_id: client_id,
      client_secret: client_secret,
      token_endpoint: Keyword.get(opts, :token_endpoint, "https://example.com/oauth2/token"),
      scopes: Keyword.get(opts, :scopes, ["read", "write"])
    )
  end

  # -- Tests -----------------------------------------------------------------

  describe "load credential not found" do
    test "returns :not_found for a key that was never stored" do
      {:ok, store} = InMemoryStore.start_link()
      assert :not_found = InMemoryStore.get("nonexistent_key", server: store)
    end
  end

  describe "save and load credential" do
    test "round-trips a credential via put/get" do
      {:ok, store} = InMemoryStore.start_link()
      cred = oauth2_cred("mock_client_id", "mock_client_secret")

      :ok = InMemoryStore.put("oauth2_cred", cred, server: store)
      assert {:ok, loaded} = InMemoryStore.get("oauth2_cred", server: store)
      assert loaded == cred
      assert loaded.type == :oauth2
      assert loaded.client_id == "mock_client_id"
    end
  end

  describe "save credential updates existing" do
    test "overwriting a key replaces the stored credential" do
      {:ok, store} = InMemoryStore.start_link()
      original = oauth2_cred("original_id", "original_secret")
      :ok = InMemoryStore.put("service", original, server: store)

      updated = oauth2_cred("updated_id", "updated_secret")
      :ok = InMemoryStore.put("service", updated, server: store)

      assert {:ok, loaded} = InMemoryStore.get("service", server: store)
      assert loaded.client_id == "updated_id"
      assert loaded.client_secret == "updated_secret"
    end
  end

  describe "credentials isolated by context (session)" do
    test "separate store processes cannot see each other's credentials" do
      {:ok, store_a} = InMemoryStore.start_link()
      {:ok, store_b} = InMemoryStore.start_link()

      cred = oauth2_cred("session_a_client", "session_a_secret")
      :ok = InMemoryStore.put("service", cred, server: store_a)

      # store_b should not have it
      assert :not_found = InMemoryStore.get("service", server: store_b)

      # store_a still has it
      assert {:ok, ^cred} = InMemoryStore.get("service", server: store_a)
    end
  end

  describe "multiple credentials same context" do
    test "different keys store different credentials in the same store" do
      {:ok, store} = InMemoryStore.start_link()

      cred1 = oauth2_cred("client1", "secret1")
      cred2 = oauth2_cred("client2", "secret2")

      :ok = InMemoryStore.put("key1", cred1, server: store)
      :ok = InMemoryStore.put("key2", cred2, server: store)

      assert {:ok, loaded1} = InMemoryStore.get("key1", server: store)
      assert {:ok, loaded2} = InMemoryStore.get("key2", server: store)
      assert loaded1.client_id == "client1"
      assert loaded2.client_id == "client2"
    end
  end

  describe "save credential with nil value" do
    test "storing nil under a key effectively clears it (returns :not_found)" do
      {:ok, store} = InMemoryStore.start_link()

      # First store a real credential
      cred = oauth2_cred("temp_id", "temp_secret")
      :ok = InMemoryStore.put("service", cred, server: store)
      assert {:ok, _} = InMemoryStore.get("service", server: store)

      # Overwrite with nil — InMemoryStore treats nil as absent
      :ok = InMemoryStore.put("service", nil, server: store)
      assert :not_found = InMemoryStore.get("service", server: store)
    end
  end

  describe "load credential with empty key" do
    test "empty string key that was never set returns :not_found" do
      {:ok, store} = InMemoryStore.start_link()
      assert :not_found = InMemoryStore.get("", server: store)
    end
  end

  describe "state persistence across operations" do
    test "credential persists through save → load → update → load cycle" do
      {:ok, store} = InMemoryStore.start_link()
      cred = oauth2_cred("initial_id", "initial_secret")

      # Save
      :ok = InMemoryStore.put("service", cred, server: store)

      # Load — still there
      assert {:ok, ^cred} = InMemoryStore.get("service", server: store)

      # Update
      updated = oauth2_cred("updated_id", "updated_secret")
      :ok = InMemoryStore.put("service", updated, server: store)

      # Load again — reflects update
      assert {:ok, loaded} = InMemoryStore.get("service", server: store)
      assert loaded.client_id == "updated_id"
      assert loaded.client_secret == "updated_secret"
    end
  end

  describe "credential key uniqueness" do
    test "distinct keys store independent credentials" do
      {:ok, store} = InMemoryStore.start_link()

      cred1 = oauth2_cred("client1", "secret1")
      cred2 = oauth2_cred("client2", "secret2")

      :ok = InMemoryStore.put("unique_key_1", cred1, server: store)
      :ok = InMemoryStore.put("unique_key_2", cred2, server: store)

      assert {:ok, l1} = InMemoryStore.get("unique_key_1", server: store)
      assert {:ok, l2} = InMemoryStore.get("unique_key_2", server: store)
      assert l1 != l2
      assert l1.client_id == "client1"
      assert l2.client_id == "client2"
    end
  end

  describe "delete credential" do
    test "deleting a credential makes it unavailable" do
      {:ok, store} = InMemoryStore.start_link()
      cred = oauth2_cred("to_delete", "secret")

      :ok = InMemoryStore.put("ephemeral", cred, server: store)
      assert {:ok, _} = InMemoryStore.get("ephemeral", server: store)

      :ok = InMemoryStore.delete("ephemeral", server: store)
      assert :not_found = InMemoryStore.get("ephemeral", server: store)
    end

    test "deleting a nonexistent key is a no-op" do
      {:ok, store} = InMemoryStore.start_link()
      assert :ok = InMemoryStore.delete("never_stored", server: store)
    end
  end

  describe "credential type variants" do
    test "stores and retrieves api_key credentials" do
      {:ok, store} = InMemoryStore.start_link()
      cred = Credential.api_key("sk-test-123")

      :ok = InMemoryStore.put("api_svc", cred, server: store)
      assert {:ok, loaded} = InMemoryStore.get("api_svc", server: store)
      assert loaded.type == :api_key
      assert loaded.api_key == "sk-test-123"
    end

    test "stores and retrieves http_bearer credentials" do
      {:ok, store} = InMemoryStore.start_link()
      cred = Credential.http_bearer("bearer-token-xyz")

      :ok = InMemoryStore.put("bearer_svc", cred, server: store)
      assert {:ok, loaded} = InMemoryStore.get("bearer_svc", server: store)
      assert loaded.type == :http_bearer
      assert loaded.access_token == "bearer-token-xyz"
    end

    test "stores and retrieves service_account credentials" do
      {:ok, store} = InMemoryStore.start_link()
      key_data = %{"type" => "service_account", "project_id" => "my-project"}
      cred = Credential.service_account(key_data, scopes: ["cloud-platform"])

      :ok = InMemoryStore.put("sa_svc", cred, server: store)
      assert {:ok, loaded} = InMemoryStore.get("sa_svc", server: store)
      assert loaded.type == :service_account
      assert loaded.service_account_key == key_data
    end
  end
end
