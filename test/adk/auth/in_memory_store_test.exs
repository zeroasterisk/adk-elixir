defmodule ADK.Auth.InMemoryStoreParityTest do
  @moduledoc """
  Tests for ADK.Auth.InMemoryStore — in-memory credential storage.

  Ported from Python ADK's test_in_memory_credential_service.py.
  Covers CRUD operations, isolation between stores, update semantics,
  and multiple credentials under different keys.
  """
  use ExUnit.Case, async: true

  alias ADK.Auth.{Credential, InMemoryStore}

  setup do
    {:ok, store} = InMemoryStore.start_link()
    %{store: store}
  end

  describe "initialization" do
    test "starts with empty store — get returns :not_found", %{store: store} do
      assert :not_found = InMemoryStore.get("nonexistent", server: store)
    end
  end

  describe "put and get (save/load)" do
    test "stores and retrieves a credential by name", %{store: store} do
      cred = Credential.oauth2("tok-1", client_id: "cid", client_secret: "csec")
      :ok = InMemoryStore.put("my_service", cred, server: store)

      assert {:ok, loaded} = InMemoryStore.get("my_service", server: store)
      assert loaded.type == :oauth2
      assert loaded.client_id == "cid"
      assert loaded.access_token == "tok-1"
    end

    test "returns :not_found for a key that was never stored", %{store: store} do
      assert :not_found = InMemoryStore.get("missing_key", server: store)
    end
  end

  describe "update (save overwrites existing)" do
    test "putting the same key twice overwrites the credential", %{store: store} do
      cred1 = Credential.oauth2("tok-old", client_id: "old_id", client_secret: "old_sec")
      :ok = InMemoryStore.put("svc", cred1, server: store)

      cred2 = Credential.oauth2("tok-new", client_id: "new_id", client_secret: "new_sec")
      :ok = InMemoryStore.put("svc", cred2, server: store)

      assert {:ok, loaded} = InMemoryStore.get("svc", server: store)
      assert loaded.client_id == "new_id"
      assert loaded.access_token == "tok-new"
    end
  end

  describe "delete" do
    test "removes a stored credential", %{store: store} do
      cred = Credential.api_key("key-1")
      :ok = InMemoryStore.put("api", cred, server: store)
      assert {:ok, _} = InMemoryStore.get("api", server: store)

      :ok = InMemoryStore.delete("api", server: store)
      assert :not_found = InMemoryStore.get("api", server: store)
    end

    test "deleting a non-existent key is a no-op", %{store: store} do
      # Should not raise
      :ok = InMemoryStore.delete("ghost", server: store)
    end
  end

  describe "isolation between store instances" do
    test "credentials are isolated between separate store processes", %{store: store1} do
      {:ok, store2} = InMemoryStore.start_link()

      cred = Credential.api_key("secret-abc")
      :ok = InMemoryStore.put("svc", cred, server: store1)

      # store2 should NOT have it
      assert :not_found = InMemoryStore.get("svc", server: store2)

      # store1 still has it
      assert {:ok, _} = InMemoryStore.get("svc", server: store1)
    end
  end

  describe "multiple credentials under different keys" do
    test "stores and retrieves multiple credentials independently", %{store: store} do
      cred1 = Credential.oauth2("tok-a", client_id: "client-a", client_secret: "sec-a")
      cred2 = Credential.oauth2("tok-b", client_id: "client-b", client_secret: "sec-b")

      :ok = InMemoryStore.put("service_a", cred1, server: store)
      :ok = InMemoryStore.put("service_b", cred2, server: store)

      assert {:ok, loaded1} = InMemoryStore.get("service_a", server: store)
      assert {:ok, loaded2} = InMemoryStore.get("service_b", server: store)

      assert loaded1.client_id == "client-a"
      assert loaded2.client_id == "client-b"
    end

    test "deleting one key does not affect another", %{store: store} do
      :ok = InMemoryStore.put("keep", Credential.api_key("k1"), server: store)
      :ok = InMemoryStore.put("remove", Credential.api_key("k2"), server: store)

      :ok = InMemoryStore.delete("remove", server: store)

      assert {:ok, _} = InMemoryStore.get("keep", server: store)
      assert :not_found = InMemoryStore.get("remove", server: store)
    end
  end

  describe "credential types round-trip" do
    test "api_key credential round-trips", %{store: store} do
      cred = Credential.api_key("my-api-key")
      :ok = InMemoryStore.put("api", cred, server: store)
      assert {:ok, loaded} = InMemoryStore.get("api", server: store)
      assert loaded.type == :api_key
      assert loaded.api_key == "my-api-key"
    end

    test "http_bearer credential round-trips", %{store: store} do
      cred = Credential.http_bearer("bearer-xyz")
      :ok = InMemoryStore.put("bearer", cred, server: store)
      assert {:ok, loaded} = InMemoryStore.get("bearer", server: store)
      assert loaded.type == :http_bearer
      assert loaded.access_token == "bearer-xyz"
    end

    test "service_account credential round-trips", %{store: store} do
      key_data = %{"type" => "service_account", "project_id" => "proj-1"}
      cred = Credential.service_account(key_data, scopes: ["read"])
      :ok = InMemoryStore.put("sa", cred, server: store)
      assert {:ok, loaded} = InMemoryStore.get("sa", server: store)
      assert loaded.type == :service_account
      assert loaded.service_account_key == key_data
      assert loaded.scopes == ["read"]
    end

    test "open_id_connect credential round-trips", %{store: store} do
      cred = Credential.open_id_connect("oidc-tok", client_id: "oidc-cid")
      :ok = InMemoryStore.put("oidc", cred, server: store)
      assert {:ok, loaded} = InMemoryStore.get("oidc", server: store)
      assert loaded.type == :open_id_connect
      assert loaded.access_token == "oidc-tok"
      assert loaded.client_id == "oidc-cid"
    end
  end

  describe "behaviour compliance" do
    test "InMemoryStore implements CredentialStore behaviour" do
      behaviours =
        ADK.Auth.InMemoryStore.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ADK.Auth.CredentialStore in behaviours
    end
  end
end
