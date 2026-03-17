defmodule ADK.Auth.AuthConfigTest do
  @moduledoc """
  Parity tests for Python ADK's `test_auth_config.py`.

  Tests credential key generation: custom keys, auto-generated keys,
  stability across calls, and independence from transient credential fields.
  """
  use ExUnit.Case, async: true

  alias ADK.Auth.Config
  alias ADK.Auth.Credential

  # -- Fixtures ---------------------------------------------------------------

  defp oauth2_credentials do
    Credential.oauth2(nil,
      client_id: "mock_client_id",
      client_secret: "mock_client_secret"
    )
  end

  defp auth_config do
    Config.new(
      credential_type: :oauth2,
      scopes: ["read", "write"],
      raw_credential: oauth2_credentials(),
      exchanged_credential: oauth2_credentials()
    )
  end

  defp auth_config_with_key do
    Config.new(
      credential_type: :oauth2,
      raw_credential: oauth2_credentials(),
      credential_key: "test_key"
    )
  end

  # -- Tests: custom credential key (test_custom_credential_key) --------------

  describe "custom credential key" do
    test "returns explicit credential_key when set" do
      config = auth_config_with_key()
      assert Config.credential_key(config) == "test_key"
    end

    test "explicit key takes precedence over auto-generation" do
      config =
        Config.new(
          credential_type: :oauth2,
          raw_credential: oauth2_credentials(),
          credential_key: "my_custom_key"
        )

      assert Config.credential_key(config) == "my_custom_key"
    end
  end

  # -- Tests: auto-generated credential key (test_credential_key) -------------

  describe "auto-generated credential key" do
    test "starts with adk_ prefix" do
      config = auth_config()
      key = Config.credential_key(config)
      assert String.starts_with?(key, "adk_")
    end

    test "contains credential type" do
      config = auth_config()
      key = Config.credential_key(config)
      assert String.contains?(key, "oauth2")
    end

    test "is deterministic across calls" do
      config = auth_config()
      key1 = Config.credential_key(config)
      key2 = Config.credential_key(config)
      assert key1 == key2
    end

    test "different credentials produce different keys" do
      config1 = auth_config()

      config2 =
        Config.new(
          credential_type: :oauth2,
          raw_credential:
            Credential.oauth2(nil,
              client_id: "other_client_id",
              client_secret: "other_secret"
            )
        )

      refute Config.credential_key(config1) == Config.credential_key(config2)
    end

    test "different credential types produce different keys" do
      oauth_config =
        Config.new(
          credential_type: :oauth2,
          raw_credential: oauth2_credentials()
        )

      api_key_config =
        Config.new(
          credential_type: :api_key,
          raw_credential: Credential.api_key("test-key-123")
        )

      refute Config.credential_key(oauth_config) == Config.credential_key(api_key_config)
    end
  end

  # -- Tests: key stability (test_credential_key_is_stable) -------------------

  describe "credential key stability" do
    test "same inputs produce same key across different struct instances" do
      make_config = fn ->
        Config.new(
          credential_type: :oauth2,
          scopes: ["read"],
          raw_credential:
            Credential.oauth2(nil,
              client_id: "mock_client_id",
              client_secret: "mock_client_secret"
            )
        )
      end

      key1 = Config.credential_key(make_config.())
      key2 = Config.credential_key(make_config.())
      assert key1 == key2
    end

    test "transient oauth2 fields do not affect the key" do
      # The key should be based on stable fields (client_id, client_secret, etc.)
      # and NOT on transient fields (access_token, refresh_token, auth_code, etc.)
      base_cred =
        Credential.oauth2(nil,
          client_id: "mock_client_id",
          client_secret: "mock_client_secret"
        )

      cred_with_tokens =
        Credential.oauth2("access-tok-123",
          client_id: "mock_client_id",
          client_secret: "mock_client_secret",
          refresh_token: "ref-456",
          auth_code: "code-789"
        )

      config1 = Config.new(credential_type: :oauth2, raw_credential: base_cred)
      config2 = Config.new(credential_type: :oauth2, raw_credential: cred_with_tokens)

      assert Config.credential_key(config1) == Config.credential_key(config2)
    end

    test "metadata does not affect the key" do
      cred1 =
        Credential.oauth2(nil,
          client_id: "mock_client_id",
          client_secret: "mock_client_secret"
        )

      cred2 =
        Credential.oauth2(nil,
          client_id: "mock_client_id",
          client_secret: "mock_client_secret",
          metadata: %{"extra_field" => "value"}
        )

      config1 = Config.new(credential_type: :oauth2, raw_credential: cred1)
      config2 = Config.new(credential_type: :oauth2, raw_credential: cred2)

      assert Config.credential_key(config1) == Config.credential_key(config2)
    end
  end

  # -- Tests: config without raw_credential -----------------------------------

  describe "config without raw_credential" do
    test "generates key from type alone" do
      config = Config.new(credential_type: :api_key)
      key = Config.credential_key(config)
      assert key == "adk_api_key"
    end

    test "different types produce different bare keys" do
      key1 = Config.credential_key(Config.new(credential_type: :oauth2))
      key2 = Config.credential_key(Config.new(credential_type: :api_key))
      key3 = Config.credential_key(Config.new(credential_type: :service_account))
      assert key1 != key2
      assert key2 != key3
      assert key1 != key3
    end
  end

  # -- Tests: edge cases ------------------------------------------------------

  describe "edge cases" do
    test "empty string credential_key falls back to auto-generation" do
      config = Config.new(credential_type: :oauth2, credential_key: "")
      key = Config.credential_key(config)
      assert String.starts_with?(key, "adk_")
    end

    test "nil credential_key falls back to auto-generation" do
      config = Config.new(credential_type: :oauth2, credential_key: nil)
      key = Config.credential_key(config)
      assert String.starts_with?(key, "adk_")
    end

    test "service_account credential produces stable key" do
      sa_key = %{"project_id" => "proj-1", "private_key" => "pk"}

      config =
        Config.new(
          credential_type: :service_account,
          raw_credential: Credential.service_account(sa_key, scopes: ["cloud-platform"])
        )

      key1 = Config.credential_key(config)
      key2 = Config.credential_key(config)
      assert key1 == key2
      assert String.starts_with?(key1, "adk_service_account_")
    end
  end
end
