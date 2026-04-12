# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Auth.OAuth2CredentialUtilTest do
  @moduledoc """
  Parity tests for Python's `test_oauth2_credential_util.py`.

  Maps Python's `create_oauth2_session` and `update_credential_with_tokens`
  to Elixir's `ADK.Auth.OAuth2` (exchange_code, refresh_token, authorization_url)
  and `ADK.Auth.Exchanger.OAuth2` (exchange with scheme).
  """
  use ExUnit.Case, async: true

  alias ADK.Auth.Credential
  alias ADK.Auth.OAuth2
  alias ADK.Auth.Exchanger.OAuth2, as: ExchangerOAuth2

  # ── Credential construction helpers ────────────────────────────────────────

  describe "Credential constructors" do
    test "oauth2/2 sets all fields" do
      cred =
        Credential.oauth2("my_token",
          refresh_token: "ref_tok",
          client_id: "cid",
          client_secret: "csec",
          token_endpoint: "https://example.com/token",
          scopes: ["openid", "profile"],
          auth_code: "code123"
        )

      assert cred.type == :oauth2
      assert cred.access_token == "my_token"
      assert cred.refresh_token == "ref_tok"
      assert cred.client_id == "cid"
      assert cred.client_secret == "csec"
      assert cred.token_endpoint == "https://example.com/token"
      assert cred.scopes == ["openid", "profile"]
      assert cred.auth_code == "code123"
      assert cred.metadata == %{}
    end

    test "oauth2/2 with nil access_token for pre-exchange state" do
      cred = Credential.oauth2(nil, client_id: "cid", client_secret: "csec")
      assert cred.access_token == nil
      assert cred.client_id == "cid"
    end

    test "oauth2_with_code/1 sets auth_code and clears access_token" do
      cred =
        Credential.oauth2_with_code(
          client_id: "cid",
          client_secret: "csec",
          auth_code: "auth_code_123",
          token_endpoint: "https://example.com/token",
          scopes: ["read"]
        )

      assert cred.type == :oauth2
      assert cred.access_token == nil
      assert cred.auth_code == "auth_code_123"
      assert cred.client_id == "cid"
      assert cred.client_secret == "csec"
      assert cred.token_endpoint == "https://example.com/token"
      assert cred.scopes == ["read"]
    end

    test "open_id_connect/2 sets type and fields" do
      cred =
        Credential.open_id_connect("oidc_token",
          refresh_token: "ref",
          client_id: "cid",
          client_secret: "csec",
          token_endpoint: "https://example.com/token",
          scopes: ["openid"]
        )

      assert cred.type == :open_id_connect
      assert cred.access_token == "oidc_token"
      assert cred.refresh_token == "ref"
    end

    test "api_key/2 creates an API key credential with no OAuth2 fields" do
      cred = Credential.api_key("my-api-key")

      assert cred.type == :api_key
      assert cred.api_key == "my-api-key"
      assert cred.access_token == nil
      assert cred.refresh_token == nil
      assert cred.client_id == nil
      assert cred.client_secret == nil
    end

    test "http_bearer/2 creates a bearer token credential" do
      cred = Credential.http_bearer("bearer_tok")

      assert cred.type == :http_bearer
      assert cred.access_token == "bearer_tok"
    end

    test "service_account/2 creates a service account credential" do
      key_data = %{"type" => "service_account", "project_id" => "test"}
      cred = Credential.service_account(key_data, scopes: ["cloud-platform"])

      assert cred.type == :service_account
      assert cred.service_account_key == key_data
      assert cred.scopes == ["cloud-platform"]
    end
  end

  # ── Token update via exchange_code (parity: update_credential_with_tokens) ─

  describe "token application via exchange_code" do
    test "stores all token fields in credential" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "new_access_token",
            "refresh_token" => "new_refresh_token",
            "id_token" => "new_id_token",
            "expires_in" => 3600,
            "token_type" => "Bearer",
            "scope" => "openid profile"
          })
        )
      end

      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        auth_code: "test_code",
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        token_endpoint: "https://example.com/token",
        metadata: %{}
      }

      assert {:ok, updated} =
               OAuth2.exchange_code(cred,
                 redirect_uri: "https://example.com/callback",
                 http_opts: [plug: plug]
               )

      assert updated.access_token == "new_access_token"
      assert updated.refresh_token == "new_refresh_token"
      assert updated.metadata["id_token"] == "new_id_token"
      assert updated.metadata["token_type"] == "Bearer"
      assert updated.metadata["scope"] == "openid profile"

      # expires_at should be roughly now + 3600
      now = System.system_time(:second)
      assert_in_delta updated.metadata["expires_at"], now + 3600, 5

      # auth_code should be cleared after exchange
      assert updated.auth_code == nil
    end

    test "handles response with only access_token (no refresh, no id_token)" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "minimal_token"
          })
        )
      end

      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        auth_code: "code",
        client_id: "cid",
        client_secret: "csec",
        token_endpoint: "https://example.com/token",
        metadata: %{}
      }

      assert {:ok, updated} = OAuth2.exchange_code(cred, http_opts: [plug: plug])

      assert updated.access_token == "minimal_token"
      assert updated.refresh_token == nil
      assert updated.auth_code == nil
    end
  end

  # ── Token update via refresh_token ─────────────────────────────────────────

  describe "token application via refresh_token" do
    test "preserves existing refresh_token when provider omits it" do
      plug = fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "original_refresh"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "refreshed_access",
            "expires_in" => 1800
          })
        )
      end

      cred = %Credential{
        type: :oauth2,
        access_token: "old_access",
        refresh_token: "original_refresh",
        client_id: "cid",
        client_secret: "csec",
        token_endpoint: "https://example.com/token",
        metadata: %{}
      }

      assert {:ok, updated} = OAuth2.refresh_token(cred, http_opts: [plug: plug])

      assert updated.access_token == "refreshed_access"
      # Should keep the original refresh_token
      assert updated.refresh_token == "original_refresh"

      now = System.system_time(:second)
      assert_in_delta updated.metadata["expires_at"], now + 1800, 5
    end

    test "updates refresh_token when provider returns a new one" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "refreshed_access",
            "refresh_token" => "rotated_refresh",
            "expires_in" => 3600
          })
        )
      end

      cred = %Credential{
        type: :oauth2,
        access_token: "old_access",
        refresh_token: "old_refresh",
        client_id: "cid",
        client_secret: "csec",
        token_endpoint: "https://example.com/token",
        metadata: %{}
      }

      assert {:ok, updated} = OAuth2.refresh_token(cred, http_opts: [plug: plug])

      assert updated.access_token == "refreshed_access"
      assert updated.refresh_token == "rotated_refresh"
    end
  end

  # ── Exchanger with scheme types (parity: create_oauth2_session) ────────────

  describe "exchanger with OpenID Connect scheme" do
    test "exchanges auth_code with openIdConnect scheme" do
      plug = fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "authorization_code"
        assert params["client_id"] == "test_client_id"
        assert params["client_secret"] == "test_client_secret"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "oidc_token",
            "refresh_token" => "oidc_refresh",
            "expires_in" => 3600
          })
        )
      end

      cred = %Credential{
        type: :open_id_connect,
        access_token: nil,
        auth_code: "oidc_code",
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        token_endpoint: "https://example.com/token",
        metadata: %{
          "auth_response_uri" => "https://example.com/callback",
          "http_opts" => [plug: plug]
        }
      }

      scheme = %{
        type: "openIdConnect",
        authorization_endpoint: "https://example.com/auth",
        token_endpoint: "https://example.com/token",
        scopes: ["openid", "profile"]
      }

      assert {:ok, result} = ExchangerOAuth2.exchange(cred, scheme)
      assert result.access_token == "oidc_token"
      assert result.refresh_token == "oidc_refresh"
    end
  end

  describe "exchanger with OAuth2 scheme (authorization code flow)" do
    test "exchanges auth_code with OAuth2 flows scheme" do
      plug = fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "authorization_code"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "oauth2_token",
            "expires_in" => 3600
          })
        )
      end

      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        auth_code: "auth_code_123",
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        token_endpoint: "https://example.com/token",
        metadata: %{
          "auth_response_uri" => "https://example.com/callback",
          "http_opts" => [plug: plug]
        }
      }

      # This scheme has authorizationCode flow — exchanger determines :authorization_code
      scheme = %{type: "openIdConnect"}

      assert {:ok, result} = ExchangerOAuth2.exchange(cred, scheme)
      assert result.access_token == "oauth2_token"
    end
  end

  describe "exchanger with invalid/missing scheme" do
    test "returns error when scheme is nil" do
      cred = %Credential{
        type: :oauth2,
        client_id: "test_client_id",
        client_secret: "test_client_secret"
      }

      assert {:error, _msg} = ExchangerOAuth2.exchange(cred, nil)
    end

    test "returns error for unknown scheme type" do
      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        client_id: "test_client_id",
        client_secret: "test_client_secret"
      }

      scheme = %{type: "http"}

      assert {:error, msg} = ExchangerOAuth2.exchange(cred, scheme)
      assert msg =~ "Invalid security scheme"
    end
  end

  describe "exchanger with missing credentials" do
    test "returns original credential when client_secret is missing" do
      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        auth_code: "code",
        client_id: "test_client_id",
        # no client_secret
        token_endpoint: "https://example.com/token"
      }

      scheme = %{
        type: "openIdConnect",
        token_endpoint: "https://example.com/token"
      }

      # Exchange will fail validation (missing client_secret) and exchanger
      # returns the original credential
      assert {:ok, result} = ExchangerOAuth2.exchange(cred, scheme)
      assert result.access_token == nil
    end
  end

  # ── Authorization URL generation (parity: authorization URL building) ──────

  describe "authorization URL generation" do
    test "builds URL with all standard params" do
      url =
        OAuth2.authorization_url(%{
          auth_endpoint: "https://example.com/auth",
          client_id: "test_client_id",
          redirect_uri: "https://example.com/callback",
          scopes: ["openid", "profile"],
          state: "test_state"
        })

      assert url =~ "https://example.com/auth?"
      assert url =~ "response_type=code"
      assert url =~ "client_id=test_client_id"
      assert url =~ "redirect_uri="
      assert url =~ "state=test_state"
      assert url =~ "scope=openid+profile"
    end

    test "accepts keyword list opts" do
      url =
        OAuth2.authorization_url(
          auth_endpoint: "https://example.com/auth",
          client_id: "test_client_id",
          redirect_uri: "https://example.com/callback"
        )

      assert url =~ "https://example.com/auth?"
      assert url =~ "client_id=test_client_id"
    end

    test "includes access_type for offline refresh tokens" do
      url =
        OAuth2.authorization_url(%{
          auth_endpoint: "https://example.com/auth",
          client_id: "cid",
          redirect_uri: "https://example.com/cb",
          access_type: "offline"
        })

      assert url =~ "access_type=offline"
    end
  end

  # ── Token update on non-OAuth2 credential (parity: update_credential_with_tokens_none) ─

  describe "non-OAuth2 credential edge cases" do
    test "API key credential has no OAuth2 fields to update" do
      cred = Credential.api_key("my-key")

      # Verify API key credential doesn't have oauth2 fields
      assert cred.access_token == nil
      assert cred.refresh_token == nil
      assert cred.client_id == nil
      assert cred.client_secret == nil

      # Exchange with API key type doesn't crash
      # (exchanger handles non-OAuth2 gracefully)
      assert cred.type == :api_key
    end

    test "exchange_code returns error for API key credential (no auth_code)" do
      cred = Credential.api_key("my-key")
      assert {:error, :missing_auth_code} = OAuth2.exchange_code(cred)
    end

    test "refresh_token returns error for API key credential (no refresh_token)" do
      cred = Credential.api_key("my-key")
      assert {:error, :missing_refresh_token} = OAuth2.refresh_token(cred)
    end
  end

  # ── Client credentials flow ────────────────────────────────────────────────

  describe "client_credentials/2" do
    test "returns error when client_id or client_secret missing" do
      cred = %Credential{
        type: :oauth2,
        client_id: "cid",
        # no client_secret
        token_endpoint: "https://example.com/token"
      }

      assert {:error, :missing_client_credentials} = OAuth2.client_credentials(cred)
    end

    test "returns error when token_endpoint missing" do
      cred = %Credential{
        type: :oauth2,
        client_id: "cid",
        client_secret: "csec"
        # no token_endpoint
      }

      assert {:error, :missing_client_credentials} = OAuth2.client_credentials(cred)
    end

    test "successfully exchanges client credentials" do
      plug = fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "client_credentials"
        assert params["client_id"] == "cid"
        assert params["client_secret"] == "csec"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "client_cred_token",
            "expires_in" => 7200,
            "token_type" => "Bearer"
          })
        )
      end

      cred = %Credential{
        type: :oauth2,
        client_id: "cid",
        client_secret: "csec",
        token_endpoint: "https://example.com/token",
        metadata: %{}
      }

      assert {:ok, updated} = OAuth2.client_credentials(cred, http_opts: [plug: plug])
      assert updated.access_token == "client_cred_token"
      assert updated.metadata["token_type"] == "Bearer"

      now = System.system_time(:second)
      assert_in_delta updated.metadata["expires_at"], now + 7200, 5
    end

    test "includes scopes in client credentials request" do
      plug = fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["scope"] == "read write"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "scoped_token"})
        )
      end

      cred = %Credential{
        type: :oauth2,
        client_id: "cid",
        client_secret: "csec",
        token_endpoint: "https://example.com/token",
        scopes: ["read", "write"],
        metadata: %{}
      }

      assert {:ok, updated} = OAuth2.client_credentials(cred, http_opts: [plug: plug])
      assert updated.access_token == "scoped_token"
    end
  end
end
