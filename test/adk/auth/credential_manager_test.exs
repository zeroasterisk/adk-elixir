defmodule ADK.Auth.CredentialManagerTest do
  use ExUnit.Case, async: true

  alias ADK.Auth.{Credential, CredentialManager, InMemoryStore}

  setup do
    {:ok, store} = InMemoryStore.start_link()
    %{store: store}
  end

  describe "get_credential/3 — simple types" do
    test "returns api_key credential immediately without touching store" do
      cred = Credential.api_key("sk-test")
      assert {:ok, ^cred} = CredentialManager.get_credential("svc", cred)
    end

    test "returns http_bearer credential immediately" do
      cred = Credential.http_bearer("bearer-xyz")
      assert {:ok, ^cred} = CredentialManager.get_credential("svc", cred)
    end
  end

  describe "get_credential/3 — stored credentials" do
    test "returns stored credential when not near-expiry", %{store: store} do
      future = System.system_time(:second) + 7200

      stored = %Credential{
        type: :oauth2,
        access_token: "stored-tok",
        metadata: %{"expires_at" => future}
      }

      :ok = InMemoryStore.put("svc", stored, server: store)

      # raw_cred is irrelevant here — it finds the stored one
      raw =
        Credential.oauth2(nil,
          client_id: "c1",
          client_secret: "s1",
          token_endpoint: "https://auth.example.com/token"
        )

      assert {:ok, ^stored} = CredentialManager.get_credential("svc", raw, server: store)
    end

    test "returns stored credential with no expiry info", %{store: store} do
      stored = Credential.oauth2("no-expiry-tok")
      :ok = InMemoryStore.put("svc", stored, server: store)

      raw = Credential.oauth2(nil)
      assert {:ok, ^stored} = CredentialManager.get_credential("svc", raw, server: store)
    end
  end

  describe "get_credential/3 — needs_auth" do
    test "returns :needs_auth when no stored credential and no way to get one", %{store: store} do
      raw = Credential.oauth2(nil)
      assert :needs_auth = CredentialManager.get_credential("svc", raw, server: store)
    end

    test "returns :needs_auth for oauth2 with no auth_code and no client_secret", %{store: store} do
      raw = %Credential{type: :oauth2, access_token: nil}
      assert :needs_auth = CredentialManager.get_credential("missing", raw, server: store)
    end
  end

  describe "save_credential/3 and delete_credential/2" do
    test "save stores and retrieve works", %{store: store} do
      cred = Credential.api_key("key-123")
      :ok = CredentialManager.save_credential("my_api", cred, server: store)
      assert {:ok, ^cred} = InMemoryStore.get("my_api", server: store)
    end

    test "delete removes stored credential", %{store: store} do
      cred = Credential.api_key("key-456")
      :ok = InMemoryStore.put("my_api", cred, server: store)
      :ok = CredentialManager.delete_credential("my_api", server: store)
      assert :not_found = InMemoryStore.get("my_api", server: store)
    end
  end

  describe "Credential.oauth2_with_code/4" do
    test "creates credential with auth_code set and no access_token" do
      cred =
        Credential.oauth2_with_code("c1", "s1", "auth-code-xyz",
          token_endpoint: "https://auth.example.com/token",
          scopes: ["read"]
        )

      assert cred.type == :oauth2
      assert cred.client_id == "c1"
      assert cred.client_secret == "s1"
      assert cred.auth_code == "auth-code-xyz"
      assert cred.access_token == nil
      assert cred.token_endpoint == "https://auth.example.com/token"
      assert cred.scopes == ["read"]
    end
  end

  describe "Credential.oauth2/2 with auth_code opt" do
    test "accepts auth_code option" do
      cred =
        Credential.oauth2(nil,
          auth_code: "my-code",
          client_id: "c1",
          client_secret: "s1",
          token_endpoint: "https://auth.example.com/token"
        )

      assert cred.auth_code == "my-code"
      assert cred.access_token == nil
    end
  end
end
