defmodule ADK.Tool.Bigtable.CredentialsConfigTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.Bigtable.CredentialsConfig

  describe "BigtableCredentialsConfig validation" do
    test "test_valid_credentials_object_auth_credentials" do
      auth_creds = %{some_auth_token: "test_token"}

      config = CredentialsConfig.new!(credentials: auth_creds)

      assert config.credentials == auth_creds
      assert config.client_secret == nil

      assert config.scopes == [
               "https://www.googleapis.com/auth/bigtable.admin",
               "https://www.googleapis.com/auth/bigtable.data"
             ]
    end

    test "test_valid_credentials_object_oauth2_credentials" do
      oauth2_creds = %{
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        scopes: ["https://www.googleapis.com/auth/calendar"]
      }

      config = CredentialsConfig.new!(credentials: oauth2_creds)

      assert config.credentials == oauth2_creds
      assert config.client_id == "test_client_id"
      assert config.client_secret == "test_client_secret"
      assert config.scopes == ["https://www.googleapis.com/auth/calendar"]
    end

    test "test_valid_client_id_secret_pair_default_scope" do
      config =
        CredentialsConfig.new!(
          client_id: "test_client_id",
          client_secret: "test_client_secret"
        )

      assert config.credentials == nil
      assert config.client_id == "test_client_id"
      assert config.client_secret == "test_client_secret"

      assert config.scopes == [
               "https://www.googleapis.com/auth/bigtable.admin",
               "https://www.googleapis.com/auth/bigtable.data"
             ]
    end

    test "test_valid_client_id_secret_pair_w_scope" do
      config =
        CredentialsConfig.new!(
          client_id: "test_client_id",
          client_secret: "test_client_secret",
          scopes: [
            "https://www.googleapis.com/auth/bigtable.admin",
            "https://www.googleapis.com/auth/drive"
          ]
        )

      assert config.credentials == nil
      assert config.client_id == "test_client_id"
      assert config.client_secret == "test_client_secret"

      assert config.scopes == [
               "https://www.googleapis.com/auth/bigtable.admin",
               "https://www.googleapis.com/auth/drive"
             ]
    end

    test "test_valid_client_id_secret_pair_w_empty_scope" do
      config =
        CredentialsConfig.new!(
          client_id: "test_client_id",
          client_secret: "test_client_secret",
          scopes: []
        )

      assert config.credentials == nil
      assert config.client_id == "test_client_id"
      assert config.client_secret == "test_client_secret"

      assert config.scopes == [
               "https://www.googleapis.com/auth/bigtable.admin",
               "https://www.googleapis.com/auth/bigtable.data"
             ]
    end

    test "test_missing_client_secret_raises_error" do
      assert_raise ArgumentError,
                   ~r/Must provide one of credentials, external_access_token_key, or client_id and client_secret pair/,
                   fn ->
                     CredentialsConfig.new!(client_id: "test_client_id")
                   end
    end

    test "test_missing_client_id_raises_error" do
      assert_raise ArgumentError,
                   ~r/Must provide one of credentials, external_access_token_key, or client_id and client_secret pair/,
                   fn ->
                     CredentialsConfig.new!(client_secret: "test_client_secret")
                   end
    end

    test "test_empty_configuration_raises_error" do
      assert_raise ArgumentError,
                   ~r/Must provide one of credentials, external_access_token_key, or client_id and client_secret pair/,
                   fn ->
                     CredentialsConfig.new!()
                   end
    end

    test "test_invalid_property_raises_error" do
      assert_raise ArgumentError, ~r/Invalid properties provided/, fn ->
        CredentialsConfig.new!(
          client_id: "test_client_id",
          client_secret: "test_client_secret",
          non_existent_field: "some value"
        )
      end
    end
  end
end