defmodule ADK.Auth.Exchanger.ServiceAccountTest do
  use ExUnit.Case, async: true
  import Mox

  alias ADK.Auth.Credential
  alias ADK.Auth.Exchanger.ServiceAccount, as: Exchanger

  @default_scopes ["https://www.googleapis.com/auth/cloud-platform"]

  setup :verify_on_exit!

  setup do
    # Point the Application env to the mock for this test process
    Application.put_env(:adk, :google_auth_client, ADK.Auth.GoogleMock)

    # Simple auth scheme mock structure
    auth_scheme = %{type: "oauth2", description: "Google Service Account"}

    # A minimal valid ServiceAccountCredential representation
    sa_credential = %{
      "type" => "service_account",
      "project_id" => "test_project_id",
      "private_key_id" => "test_private_key_id",
      "private_key" => "-----BEGIN PRIVATE KEY-----...",
      "client_email" => "test@test.iam.gserviceaccount.com",
      "client_id" => "test_client_id",
      "auth_uri" => "https://accounts.google.com/o/oauth2/auth",
      "token_uri" => "https://oauth2.googleapis.com/token",
      "auth_provider_x509_cert_url" => "https://www.googleapis.com/oauth2/v1/certs",
      "client_x509_cert_url" => "https://www.googleapis.com/robot/v1/metadata/x509/test",
      "universe_domain" => "googleapis.com"
    }

    {:ok, auth_scheme: auth_scheme, sa_credential: sa_credential}
  end

  # --- Access token exchange tests ---

  test "exchange access token with explicit credentials", %{
    auth_scheme: auth_scheme,
    sa_credential: sa_credential
  } do
    ADK.Auth.GoogleMock
    |> expect(:from_service_account_info, fn ^sa_credential, scopes ->
      assert scopes == @default_scopes
      {:ok, %{token: "mock_access_token"}}
    end)

    auth_credential = Credential.service_account(sa_credential, scopes: @default_scopes)

    assert {:ok, result} = Exchanger.exchange(auth_credential, auth_scheme)
    assert result.type == :http_bearer
    assert result.access_token == "mock_access_token"
  end

  test "exchange access token with adc sets quota project", %{auth_scheme: auth_scheme} do
    # Testing parameters: cred_quota_project_id, adc_project_id, expected_quota_project_id
    cases = [
      {"test_project", "another_project", "test_project"},
      {nil, "adc_project", "adc_project"},
      {nil, nil, nil}
    ]

    # We will just run three expectations sequentially
    for {cred_quota_project_id, adc_project_id, expected_quota_project_id} <- cases do
      ADK.Auth.GoogleMock
      |> expect(:default_credentials, 1, fn scopes ->
        assert scopes == ["https://www.googleapis.com/auth/bigquery"]

        # We simulate the python logic where default_credentials returns a tuple 
        # (credentials, project_id) and then the credentials might have quota_project_id
        # In our Elixir mapping, default_credentials returns the quota_project_id directly
        quota_id = cred_quota_project_id || adc_project_id
        {:ok, %{token: "mock_access_token", quota_project_id: quota_id}}
      end)

      auth_credential =
        Credential.service_account(nil,
          scopes: ["https://www.googleapis.com/auth/bigquery"],
          metadata: %{use_default_credential: true}
        )

      assert {:ok, result} = Exchanger.exchange(auth_credential, auth_scheme)
      assert result.type == :http_bearer
      assert result.access_token == "mock_access_token"

      if expected_quota_project_id do
        assert result.metadata["additional_headers"]["x-goog-user-project"] ==
                 expected_quota_project_id
      else
        assert result.metadata["additional_headers"] == nil ||
                 map_size(result.metadata["additional_headers"]) == 0
      end
    end
  end

  test "exchange access token with adc defaults to cloud platform scope", %{
    auth_scheme: auth_scheme
  } do
    ADK.Auth.GoogleMock
    |> expect(:default_credentials, fn scopes ->
      assert scopes == @default_scopes
      {:ok, %{token: "mock_access_token", quota_project_id: nil}}
    end)

    auth_credential = Credential.service_account(nil, metadata: %{use_default_credential: true})

    assert {:ok, result} = Exchanger.exchange(auth_credential, auth_scheme)
    assert result.type == :http_bearer
    assert result.access_token == "mock_access_token"
  end

  test "exchange raises when auth credential is nil", %{auth_scheme: auth_scheme} do
    assert {:error, msg} = Exchanger.exchange(nil, auth_scheme)
    assert msg =~ "Service account credentials are missing"
  end

  test "exchange raises when service account is wrong type", %{auth_scheme: auth_scheme} do
    auth_credential = Credential.api_key("wrong")
    assert {:error, msg} = Exchanger.exchange(auth_credential, auth_scheme)
    assert msg =~ "Service account credentials are missing"
  end

  test "exchange wraps google auth error as missing error", %{
    auth_scheme: auth_scheme,
    sa_credential: sa_credential
  } do
    ADK.Auth.GoogleMock
    |> expect(:from_service_account_info, fn _, _ ->
      {:error, "Failed to load credentials"}
    end)

    auth_credential = Credential.service_account(sa_credential, scopes: @default_scopes)

    assert {:error, msg} = Exchanger.exchange(auth_credential, auth_scheme)
    assert msg =~ "Failed to exchange service account token"
  end

  test "exchange raises when explicit credentials have no scopes", %{
    auth_scheme: auth_scheme,
    sa_credential: sa_credential
  } do
    auth_credential = Credential.service_account(sa_credential, scopes: [])

    assert {:error, msg} = Exchanger.exchange(auth_credential, auth_scheme)
    assert msg =~ "scopes are required"
  end

  # --- ID token exchange tests ---

  test "exchange id token with explicit credentials", %{
    auth_scheme: auth_scheme,
    sa_credential: sa_credential
  } do
    ADK.Auth.GoogleMock
    |> expect(:from_service_account_info_id_token, fn ^sa_credential, audience ->
      assert audience == "https://my-service.run.app"
      {:ok, %{token: "mock_id_token"}}
    end)

    auth_credential =
      Credential.service_account(
        sa_credential,
        scopes: @default_scopes,
        metadata: %{use_id_token: true, audience: "https://my-service.run.app"}
      )

    assert {:ok, result} = Exchanger.exchange(auth_credential, auth_scheme)
    assert result.type == :http_bearer
    assert result.access_token == "mock_id_token"

    assert result.metadata["additional_headers"] == nil ||
             result.metadata["additional_headers"] == %{}
  end

  test "exchange id token with adc", %{auth_scheme: auth_scheme} do
    ADK.Auth.GoogleMock
    |> expect(:fetch_id_token, fn audience ->
      assert audience == "https://my-service.run.app"
      {:ok, "mock_adc_id_token"}
    end)

    auth_credential =
      Credential.service_account(
        nil,
        scopes: @default_scopes,
        metadata: %{
          use_default_credential: true,
          use_id_token: true,
          audience: "https://my-service.run.app"
        }
      )

    assert {:ok, result} = Exchanger.exchange(auth_credential, auth_scheme)
    assert result.type == :http_bearer
    assert result.access_token == "mock_adc_id_token"

    assert result.metadata["additional_headers"] == nil ||
             result.metadata["additional_headers"] == %{}
  end

  test "id token requires audience", %{auth_scheme: auth_scheme} do
    # This mirrors the python test_id_token_requires_audience validator
    auth_credential =
      Credential.service_account(
        nil,
        metadata: %{use_default_credential: true, use_id_token: true}
      )

    assert {:error, msg} = Exchanger.exchange(auth_credential, auth_scheme)
    assert msg =~ "audience is required when use_id_token is True"
  end

  test "exchange id token wraps error with explicit credentials", %{
    auth_scheme: auth_scheme,
    sa_credential: sa_credential
  } do
    ADK.Auth.GoogleMock
    |> expect(:from_service_account_info_id_token, fn _, _ ->
      {:error, "Failed to create ID token credentials"}
    end)

    auth_credential =
      Credential.service_account(
        sa_credential,
        scopes: @default_scopes,
        metadata: %{use_id_token: true, audience: "https://my-service.run.app"}
      )

    assert {:error, msg} = Exchanger.exchange(auth_credential, auth_scheme)
    assert msg =~ "Failed to exchange service account for ID token"
  end

  test "exchange id token wraps error with adc", %{auth_scheme: auth_scheme} do
    ADK.Auth.GoogleMock
    |> expect(:fetch_id_token, fn _ ->
      {:error, "Metadata service unavailable"}
    end)

    auth_credential =
      Credential.service_account(
        nil,
        scopes: @default_scopes,
        metadata: %{
          use_default_credential: true,
          use_id_token: true,
          audience: "https://my-service.run.app"
        }
      )

    assert {:error, msg} = Exchanger.exchange(auth_credential, auth_scheme)
    assert msg =~ "Failed to exchange service account for ID token"
  end

  # --- Model validator tests ---

  test "model validator rejects missing credential without adc", %{auth_scheme: auth_scheme} do
    auth_credential =
      Credential.service_account(
        nil,
        scopes: @default_scopes,
        metadata: %{use_default_credential: false}
      )

    assert {:error, msg} = Exchanger.exchange(auth_credential, auth_scheme)
    assert msg =~ "service_account_credential is required"
  end

  test "model validator allows adc without explicit credential", %{auth_scheme: auth_scheme} do
    # Handled by existing ADC tests since we pass nil for explicit credentials
    # but let's assert it specifically 
    ADK.Auth.GoogleMock
    |> expect(:default_credentials, fn scopes ->
      assert scopes == @default_scopes
      {:ok, %{token: "mock_access_token", quota_project_id: nil}}
    end)

    auth_credential =
      Credential.service_account(
        nil,
        scopes: @default_scopes,
        metadata: %{use_default_credential: true}
      )

    assert {:ok, _} = Exchanger.exchange(auth_credential, auth_scheme)
  end
end
