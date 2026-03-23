defmodule ADK.Tool.OpenApiTool.Auth.AuthHelpersTest do
  use ExUnit.Case, async: true
  alias ADK.Tool.OpenApiTool.Auth.AuthHelpers
  alias ADK.Auth.Credential

  test "token_to_scheme_credential_api_key_header" do
    {scheme, credential} = AuthHelpers.token_to_scheme_credential(
      "apikey", "header", "X-API-Key", "test_key"
    )

    assert scheme == %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}
    assert credential == Credential.api_key("test_key")
  end

  test "token_to_scheme_credential_api_key_query" do
    {scheme, credential} = AuthHelpers.token_to_scheme_credential(
      "apikey", "query", "api_key", "test_key"
    )

    assert scheme == %{"type" => "apiKey", "in" => "query", "name" => "api_key"}
    assert credential == Credential.api_key("test_key")
  end

  test "token_to_scheme_credential_api_key_cookie" do
    {scheme, credential} = AuthHelpers.token_to_scheme_credential(
      "apikey", "cookie", "session_id", "test_key"
    )

    assert scheme == %{"type" => "apiKey", "in" => "cookie", "name" => "session_id"}
    assert credential == Credential.api_key("test_key")
  end

  test "token_to_scheme_credential_api_key_no_credential" do
    {scheme, credential} = AuthHelpers.token_to_scheme_credential(
      "apikey", "cookie", "session_id"
    )

    assert scheme == %{"type" => "apiKey", "in" => "cookie", "name" => "session_id"}
    assert credential == nil
  end

  test "token_to_scheme_credential_oauth2_token" do
    {scheme, credential} = AuthHelpers.token_to_scheme_credential(
      "oauth2Token", "header", "Authorization", "test_token"
    )

    assert scheme == %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
    assert credential == Credential.http_bearer("test_token")
  end

  test "token_to_scheme_credential_oauth2_no_credential" do
    {scheme, credential} = AuthHelpers.token_to_scheme_credential(
      "oauth2Token", "header", "Authorization"
    )

    assert scheme == %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
    assert credential == nil
  end

  test "service_account_dict_to_scheme_credential" do
    config = %{
      "type" => "service_account",
      "project_id" => "project_id",
      "private_key_id" => "private_key_id",
      "private_key" => "private_key",
      "client_email" => "client_email",
      "client_id" => "client_id",
      "auth_uri" => "auth_uri",
      "token_uri" => "token_uri",
      "auth_provider_x509_cert_url" => "auth_provider_x509_cert_url",
      "client_x509_cert_url" => "client_x509_cert_url",
      "universe_domain" => "universe_domain"
    }
    scopes = ["scope1", "scope2"]

    {scheme, credential} = AuthHelpers.service_account_dict_to_scheme_credential(config, scopes)

    assert scheme == %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
    assert credential.type == :service_account
    assert credential.scopes == scopes
    assert credential.service_account_key["project_id"] == "project_id"
  end

  test "service_account_scheme_credential" do
    config = Credential.service_account(
      %{
        "type" => "service_account",
        "project_id" => "project_id",
        "private_key_id" => "private_key_id",
        "private_key" => "private_key",
        "client_email" => "client_email",
        "client_id" => "client_id",
        "auth_uri" => "auth_uri",
        "token_uri" => "token_uri",
        "auth_provider_x509_cert_url" => "auth_provider_x509_cert_url",
        "client_x509_cert_url" => "client_x509_cert_url",
        "universe_domain" => "universe_domain"
      },
      scopes: ["scope1", "scope2"]
    )

    {scheme, credential} = AuthHelpers.service_account_scheme_credential(config)

    assert scheme == %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
    assert credential.type == :service_account
    assert credential == config
  end

  test "openid_dict_to_scheme_credential" do
    config_dict = %{
      "authorization_endpoint" => "auth_url",
      "token_endpoint" => "token_url",
      "openIdConnectUrl" => "openid_url"
    }
    credential_dict = %{
      "client_id" => "client_id",
      "client_secret" => "client_secret",
      "redirect_uri" => "redirect_uri"
    }
    scopes = ["scope1", "scope2"]

    {scheme, credential} = AuthHelpers.openid_dict_to_scheme_credential(
      config_dict, scopes, credential_dict
    )

    assert scheme["authorization_endpoint"] == "auth_url"
    assert scheme["token_endpoint"] == "token_url"
    assert scheme["scopes"] == scopes
    assert credential.type == :open_id_connect
    assert credential.client_id == "client_id"
    assert credential.client_secret == "client_secret"
    assert credential.metadata["redirect_uri"] == "redirect_uri"
  end

  test "openid_dict_to_scheme_credential_no_openid_url" do
    config_dict = %{
      "authorization_endpoint" => "auth_url",
      "token_endpoint" => "token_url"
    }
    credential_dict = %{
      "client_id" => "client_id",
      "client_secret" => "client_secret",
      "redirect_uri" => "redirect_uri"
    }
    scopes = ["scope1", "scope2"]

    {scheme, _credential} = AuthHelpers.openid_dict_to_scheme_credential(
      config_dict, scopes, credential_dict
    )

    assert scheme["openIdConnectUrl"] == ""
  end

  test "openid_dict_to_scheme_credential_google_oauth_credential" do
    config_dict = %{
      "authorization_endpoint" => "auth_url",
      "token_endpoint" => "token_url",
      "openIdConnectUrl" => "openid_url"
    }
    credential_dict = %{
      "web" => %{
        "client_id" => "client_id",
        "client_secret" => "client_secret",
        "redirect_uri" => "redirect_uri"
      }
    }
    scopes = ["scope1", "scope2"]

    {scheme, credential} = AuthHelpers.openid_dict_to_scheme_credential(
      config_dict, scopes, credential_dict
    )

    assert scheme["type"] == "openIdConnect"
    assert credential.type == :open_id_connect
    assert credential.client_id == "client_id"
    assert credential.client_secret == "client_secret"
    assert credential.metadata["redirect_uri"] == "redirect_uri"
  end

  test "openid_dict_to_scheme_credential_invalid_config" do
    config_dict = %{
      "invalid_field" => "value"
    }
    credential_dict = %{
      "client_id" => "client_id",
      "client_secret" => "client_secret"
    }
    scopes = ["scope1", "scope2"]

    assert_raise ArgumentError, ~r/Invalid OpenID Connect configuration/, fn ->
      AuthHelpers.openid_dict_to_scheme_credential(config_dict, scopes, credential_dict)
    end
  end

  test "openid_dict_to_scheme_credential_missing_credential_fields" do
    config_dict = %{
      "authorization_endpoint" => "auth_url",
      "token_endpoint" => "token_url"
    }
    credential_dict = %{
      "client_id" => "client_id"
    }
    scopes = ["scope1", "scope2"]

    assert_raise ArgumentError, ~r/Missing required fields in credential_dict: client_secret/, fn ->
      AuthHelpers.openid_dict_to_scheme_credential(config_dict, scopes, credential_dict)
    end
  end


  # -- Bypass Tests for openid_url_to_scheme_credential --

  test "openid_url_to_scheme_credential" do
    bypass = Bypass.open()
    Bypass.expect(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(200, ~s({
        "authorization_endpoint": "auth_url",
        "token_endpoint": "token_url",
        "userinfo_endpoint": "userinfo_url"
      }))
    end)

    url = "http://localhost:#{bypass.port}/.well-known/openid-configuration"
    credential_dict = %{
      "client_id" => "client_id",
      "client_secret" => "client_secret",
      "redirect_uri" => "redirect_uri"
    }
    scopes = ["scope1", "scope2"]

    {scheme, credential} = AuthHelpers.openid_url_to_scheme_credential(url, scopes, credential_dict)

    assert scheme["authorization_endpoint"] == "auth_url"
    assert scheme["token_endpoint"] == "token_url"
    assert scheme["scopes"] == scopes
    assert credential.type == :open_id_connect
    assert credential.client_id == "client_id"
    assert credential.client_secret == "client_secret"
    assert credential.metadata["redirect_uri"] == "redirect_uri"
  end

  test "openid_url_to_scheme_credential_no_openid_url" do
    bypass = Bypass.open()
    Bypass.expect(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(200, ~s({
        "authorization_endpoint": "auth_url",
        "token_endpoint": "token_url",
        "userinfo_endpoint": "userinfo_url"
      }))
    end)

    url = "http://localhost:#{bypass.port}/.well-known/openid-configuration"
    credential_dict = %{
      "client_id" => "client_id",
      "client_secret" => "client_secret",
      "redirect_uri" => "redirect_uri"
    }
    scopes = ["scope1", "scope2"]

    {scheme, _credential} = AuthHelpers.openid_url_to_scheme_credential(url, scopes, credential_dict)

    assert scheme["openIdConnectUrl"] == url
  end

  test "openid_url_to_scheme_credential_request_exception" do
    bypass = Bypass.open()
    Bypass.down(bypass)

    url = "http://localhost:#{bypass.port}/.well-known/openid-configuration"
    credential_dict = %{"client_id" => "client_id", "client_secret" => "client_secret"}

    assert_raise ArgumentError, ~r/Failed to fetch OpenID configuration from http/, fn ->
      AuthHelpers.openid_url_to_scheme_credential(url, [], credential_dict)
    end
  end

  test "openid_url_to_scheme_credential_invalid_json" do
    bypass = Bypass.open()
    Bypass.expect(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(200, "Invalid JSON")
    end)

    url = "http://localhost:#{bypass.port}/.well-known/openid-configuration"
    credential_dict = %{"client_id" => "client_id", "client_secret" => "client_secret"}

    assert_raise ArgumentError, ~r/Invalid JSON response from OpenID configuration endpoint/, fn ->
      AuthHelpers.openid_url_to_scheme_credential(url, [], credential_dict)
    end
  end

  # -- credential_to_param tests --

  test "credential_to_param_api_key_header" do
    auth_scheme = %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}
    auth_credential = Credential.api_key("test_key")

    {param, kwargs} = AuthHelpers.credential_to_param(auth_scheme, auth_credential)

    assert param.original_name == "X-API-Key"
    assert param.param_location == "header"
    assert kwargs == %{"_auth_prefix_vaf_X-API-Key" => "test_key"}
  end

  test "credential_to_param_api_key_query" do
    auth_scheme = %{"type" => "apiKey", "in" => "query", "name" => "api_key"}
    auth_credential = Credential.api_key("test_key")

    {param, kwargs} = AuthHelpers.credential_to_param(auth_scheme, auth_credential)

    assert param.original_name == "api_key"
    assert param.param_location == "query"
    assert kwargs == %{"_auth_prefix_vaf_api_key" => "test_key"}
  end

  test "credential_to_param_api_key_cookie" do
    auth_scheme = %{"type" => "apiKey", "in" => "cookie", "name" => "session_id"}
    auth_credential = Credential.api_key("test_key")

    {param, kwargs} = AuthHelpers.credential_to_param(auth_scheme, auth_credential)

    assert param.original_name == "session_id"
    assert param.param_location == "cookie"
    assert kwargs == %{"_auth_prefix_vaf_session_id" => "test_key"}
  end

  test "credential_to_param_http_bearer" do
    auth_scheme = %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
    auth_credential = Credential.http_bearer("test_token")

    {param, kwargs} = AuthHelpers.credential_to_param(auth_scheme, auth_credential)

    assert param.original_name == "Authorization"
    assert param.param_location == "header"
    assert kwargs == %{"_auth_prefix_vaf_Authorization" => "Bearer test_token"}
  end

  test "credential_to_param_http_basic_not_supported" do
    auth_scheme = %{"type" => "http", "scheme" => "basic"}
    auth_credential = Credential.http_bearer("dummy", metadata: %{"basic" => true})

    assert_raise ArgumentError, ~r/Basic Authentication is not supported./, fn ->
      AuthHelpers.credential_to_param(auth_scheme, auth_credential)
    end
  end

  test "credential_to_param_http_invalid_credentials_no_http" do
    auth_scheme = %{"type" => "http", "scheme" => "basic"}
    auth_credential = Credential.http_bearer(nil)

    assert_raise ArgumentError, ~r/Invalid HTTP auth credentials/, fn ->
      AuthHelpers.credential_to_param(auth_scheme, auth_credential)
    end
  end

  test "credential_to_param_oauth2" do
    auth_scheme = %{"type" => "oauth2", "flows" => %{}}
    auth_credential = Credential.http_bearer("test_token")

    {param, kwargs} = AuthHelpers.credential_to_param(auth_scheme, auth_credential)

    assert param.original_name == "Authorization"
    assert param.param_location == "header"
    assert kwargs == %{"_auth_prefix_vaf_Authorization" => "Bearer test_token"}
  end

  test "credential_to_param_openid_connect" do
    auth_scheme = %{"type" => "openIdConnect", "openIdConnectUrl" => "openid_url"}
    auth_credential = Credential.http_bearer("test_token")

    {param, kwargs} = AuthHelpers.credential_to_param(auth_scheme, auth_credential)

    assert param.original_name == "Authorization"
    assert param.param_location == "header"
    assert kwargs == %{"_auth_prefix_vaf_Authorization" => "Bearer test_token"}
  end

  test "credential_to_param_openid_no_credential" do
    auth_scheme = %{"type" => "openIdConnect", "openIdConnectUrl" => "openid_url"}

    {param, kwargs} = AuthHelpers.credential_to_param(auth_scheme, nil)

    assert param == nil
    assert kwargs == nil
  end

  test "credential_to_param_oauth2_no_credential" do
    auth_scheme = %{"type" => "oauth2", "flows" => %{}}

    {param, kwargs} = AuthHelpers.credential_to_param(auth_scheme, nil)

    assert param == nil
    assert kwargs == nil
  end

  # -- dict_to_auth_scheme tests --

  test "dict_to_auth_scheme_api_key" do
    data = %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}
    scheme = AuthHelpers.dict_to_auth_scheme(data)

    assert scheme["type"] == "apiKey"
    assert scheme["in"] == "header"
    assert scheme["name"] == "X-API-Key"
  end

  test "dict_to_auth_scheme_http_bearer" do
    data = %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
    scheme = AuthHelpers.dict_to_auth_scheme(data)

    assert scheme["type"] == "http"
    assert scheme["scheme"] == "bearer"
    assert scheme["bearerFormat"] == "JWT"
  end

  test "dict_to_auth_scheme_http_base" do
    data = %{"type" => "http", "scheme" => "basic"}
    scheme = AuthHelpers.dict_to_auth_scheme(data)

    assert scheme["type"] == "http"
    assert scheme["scheme"] == "basic"
  end

  test "dict_to_auth_scheme_oauth2" do
    data = %{
      "type" => "oauth2",
      "flows" => %{
        "authorizationCode" => %{
          "authorizationUrl" => "https://example.com/auth",
          "tokenUrl" => "https://example.com/token"
        }
      }
    }
    scheme = AuthHelpers.dict_to_auth_scheme(data)

    assert scheme["type"] == "oauth2"
    assert scheme["flows"]["authorizationCode"] != nil
  end

  test "dict_to_auth_scheme_openid_connect" do
    data = %{
      "type" => "openIdConnect",
      "openIdConnectUrl" => "https://example.com/.well-known/openid-configuration"
    }
    scheme = AuthHelpers.dict_to_auth_scheme(data)

    assert scheme["type"] == "openIdConnect"
    assert scheme["openIdConnectUrl"] == "https://example.com/.well-known/openid-configuration"
  end

  test "dict_to_auth_scheme_missing_type" do
    data = %{"in" => "header", "name" => "X-API-Key"}
    assert_raise ArgumentError, ~r/Missing 'type' field in security scheme dictionary./, fn ->
      AuthHelpers.dict_to_auth_scheme(data)
    end
  end

  test "dict_to_auth_scheme_invalid_type" do
    data = %{"type" => "invalid", "in" => "header", "name" => "X-API-Key"}
    assert_raise ArgumentError, ~r/Invalid security scheme type: invalid/, fn ->
      AuthHelpers.dict_to_auth_scheme(data)
    end
  end

  test "dict_to_auth_scheme_invalid_data" do
    data = %{"type" => "apiKey", "in" => "header"}  # Missing 'name'
    assert_raise ArgumentError, ~r/Invalid security scheme data/, fn ->
      AuthHelpers.dict_to_auth_scheme(data)
    end
  end


end
