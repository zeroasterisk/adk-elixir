defmodule ADK.Auth.Exchanger.OAuth2Test do
  use ExUnit.Case, async: true

  alias ADK.Auth.Credential
  alias ADK.Auth.Exchanger.OAuth2

  describe "exchange/2" do
    test "exchange_with_existing_token returns the same credential without exchanging" do
      cred = %Credential{
        type: :oauth2,
        access_token: "existing_token",
        client_id: "client",
        client_secret: "secret"
      }
      scheme = %{type: "openIdConnect"}

      assert {:ok, result} = OAuth2.exchange(cred, scheme)
      assert result.access_token == "existing_token"
    end

    test "exchange_missing_auth_scheme returns an error" do
      cred = %Credential{type: :oauth2, client_id: "client"}
      assert {:error, "auth_scheme is required" <> _} = OAuth2.exchange(cred, nil)
    end

    test "exchange_no_session returns original credential on missing client_secret (validation error)" do
      # Credential without client_secret will cause validation failure in OAuth2.exchange_code
      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        auth_code: "code123",
        client_id: "client",
        token_endpoint: "https://example.com/token"
      }
      scheme = %{type: "openIdConnect"}

      assert {:ok, result} = OAuth2.exchange(cred, scheme)
      assert result == cred
      assert result.access_token == nil
    end

    test "exchange_fetch_token_failure returns original credential on HTTP error" do
      plug = fn conn ->
        conn |> Plug.Conn.send_resp(500, "Server Error")
      end

      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        auth_code: "code123",
        client_id: "client",
        client_secret: "secret",
        token_endpoint: "https://example.com/token",
        metadata: %{"http_opts" => [plug: plug]}
      }
      scheme = %{type: "openIdConnect"}

      assert {:ok, result} = OAuth2.exchange(cred, scheme)
      assert result == cred
      assert result.access_token == nil
    end

    test "exchange_success exchanges auth_code for token" do
      plug = fn conn ->
        assert conn.request_path == "/token"
        
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "authorization_code"
        assert params["code"] == "code123"
        assert params["redirect_uri"] == "https://example.com/cb"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "access_token" => "new_token",
          "refresh_token" => "new_refresh",
          "expires_in" => 3600
        }))
      end

      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        auth_code: "code123",
        client_id: "client",
        client_secret: "secret",
        token_endpoint: "https://example.com/token",
        metadata: %{
          "auth_response_uri" => "https://example.com/cb",
          "http_opts" => [plug: plug]
        }
      }
      scheme = %{type: "openIdConnect"}

      assert {:ok, result} = OAuth2.exchange(cred, scheme)
      assert result.access_token == "new_token"
      assert result.refresh_token == "new_refresh"
      assert result.auth_code == nil
    end

    test "exchange_client_credentials_success exchanges for token" do
      plug = fn conn ->
        assert conn.request_path == "/token"
        
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "client_credentials"
        assert params["client_id"] == "client"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "access_token" => "client_token",
          "expires_in" => 3600
        }))
      end

      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        client_id: "client",
        client_secret: "secret",
        metadata: %{
          "http_opts" => [plug: plug]
        }
      }
      scheme = %{
        flows: %{
          clientCredentials: %{
            tokenUrl: "https://example.com/token"
          }
        }
      }

      assert {:ok, result} = OAuth2.exchange(cred, scheme)
      assert result.access_token == "client_token"
      assert result.token_endpoint == "https://example.com/token"
    end

    test "exchange_client_credentials_failure returns original credential" do
      plug = fn conn ->
        conn |> Plug.Conn.send_resp(401, "Unauthorized")
      end

      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        client_id: "client",
        client_secret: "secret",
        metadata: %{
          "http_opts" => [plug: plug]
        }
      }
      scheme = %{
        flows: %{
          clientCredentials: %{
            tokenUrl: "https://example.com/token"
          }
        }
      }

      assert {:ok, result} = OAuth2.exchange(cred, scheme)
      assert result == %{cred | token_endpoint: "https://example.com/token"}
      assert result.access_token == nil
    end

    test "exchange_normalize_uri removes trailing hash" do
      plug = fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["redirect_uri"] == "https://example.com/cb"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "access_token" => "new_token"
        }))
      end

      cred = %Credential{
        type: :oauth2,
        access_token: nil,
        auth_code: "code123",
        client_id: "client",
        client_secret: "secret",
        token_endpoint: "https://example.com/token",
        metadata: %{
          "auth_response_uri" => "https://example.com/cb#",
          "http_opts" => [plug: plug]
        }
      }
      scheme = %{type: "openIdConnect"}

      assert {:ok, result} = OAuth2.exchange(cred, scheme)
      assert result.access_token == "new_token"
    end
  end

  describe "determine_grant_type/1" do
    test "determines client_credentials from flows" do
      scheme = %{flows: %{clientCredentials: %{tokenUrl: "url"}}}
      assert OAuth2.determine_grant_type(scheme) == :client_credentials

      scheme_snake = %{flows: %{client_credentials: %{tokenUrl: "url"}}}
      assert OAuth2.determine_grant_type(scheme_snake) == :client_credentials
    end

    test "determines client_credentials from openIdConnect with supported grants" do
      scheme = %{type: "openIdConnect", grant_types_supported: ["authorization_code", "client_credentials"]}
      assert OAuth2.determine_grant_type(scheme) == :client_credentials
    end

    test "defaults to authorization_code for openIdConnect" do
      scheme = %{type: "openIdConnect"}
      assert OAuth2.determine_grant_type(scheme) == :authorization_code
      
      scheme_unsupported = %{type: "openIdConnect", grant_types_supported: ["authorization_code"]}
      assert OAuth2.determine_grant_type(scheme_unsupported) == :authorization_code
    end

    test "returns nil for unknown scheme" do
      assert OAuth2.determine_grant_type(%{type: "http"}) == nil
      assert OAuth2.determine_grant_type(%{}) == nil
    end
  end
end
