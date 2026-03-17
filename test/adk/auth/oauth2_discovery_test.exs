defmodule ADK.Auth.OAuth2DiscoveryTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias ADK.Auth.OAuth2Discovery
  alias ADK.Auth.OAuth2.AuthorizationServerMetadata
  alias ADK.Auth.OAuth2.ProtectedResourceMetadata

  test "discover_auth_server_metadata/1 with failed responses" do
    bypass = Bypass.open()
    Bypass.down(bypass)

    assert {:error, :http_error} = OAuth2Discovery.discover_auth_server_metadata("http://localhost:#{bypass.port}")
  end

  test "discover_auth_server_metadata/1 without path" do
    bypass = Bypass.open()
    metadata = %AuthorizationServerMetadata{
      issuer: "http://localhost:#{bypass.port}",
      authorization_endpoint: "http://localhost:#{bypass.port}/authorize",
      token_endpoint: "http://localhost:#{bypass.port}/token",
      scopes_supported: ["read", "write"]
    }

    Bypass.expect(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      conn |> put_resp_content_type("application/json") |> resp(200, Jason.encode!(metadata))
    end)

    assert {:ok, result} = OAuth2Discovery.discover_auth_server_metadata("http://localhost:#{bypass.port}")
    assert result.issuer == metadata.issuer
    assert result.authorization_endpoint == metadata.authorization_endpoint
    assert result.token_endpoint == metadata.token_endpoint
    assert result.scopes_supported == metadata.scopes_supported
  end

  test "discover_auth_server_metadata/1 with path" do
    bypass = Bypass.open()
    metadata = %AuthorizationServerMetadata{
      issuer: "http://localhost:#{bypass.port}/oauth",
      authorization_endpoint: "http://localhost:#{bypass.port}/oauth/authorize",
      token_endpoint: "http://localhost:#{bypass.port}/oauth/token",
      scopes_supported: ["read", "write"]
    }

    Bypass.expect(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      conn |> resp(404, "Not Found")
    end)

    Bypass.expect(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      conn |> resp(404, "Not Found")
    end)

    Bypass.expect(bypass, "GET", "/oauth/.well-known/openid-configuration", fn conn ->
      conn |> put_resp_content_type("application/json") |> resp(200, Jason.encode!(metadata))
    end)

    assert {:ok, result} = OAuth2Discovery.discover_auth_server_metadata("http://localhost:#{bypass.port}/oauth")
    assert result.issuer == metadata.issuer
    assert result.authorization_endpoint == metadata.authorization_endpoint
    assert result.token_endpoint == metadata.token_endpoint
    assert result.scopes_supported == metadata.scopes_supported
  end

  test "discover_auth_server_metadata/1 discards mismatched issuer" do
    bypass = Bypass.open()
    metadata = %AuthorizationServerMetadata{
      issuer: "http://localhost:#{bypass.port}",
      authorization_endpoint: "http://localhost:#{bypass.port}/authorize",
      token_endpoint: "http://localhost:#{bypass.port}/token",
      scopes_supported: ["read", "write"]
    }
    bad_metadata = %AuthorizationServerMetadata{
      issuer: "http://bad.example.com",
      authorization_endpoint: "http://localhost:#{bypass.port}/authorize",
      token_endpoint: "http://localhost:#{bypass.port}/token",
      scopes_supported: ["read", "write"]
    }

    Bypass.expect(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      conn |> put_resp_content_type("application/json") |> resp(200, Jason.encode!(bad_metadata))
    end)

    Bypass.expect(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      conn |> put_resp_content_type("application/json") |> resp(200, Jason.encode!(metadata))
    end)


    assert {:ok, result} = OAuth2Discovery.discover_auth_server_metadata("http://localhost:#{bypass.port}")
    assert result.issuer == metadata.issuer
  end

  test "discover_resource_metadata/1 without path" do
    bypass = Bypass.open()
    metadata = %ProtectedResourceMetadata{
      resource: "http://localhost:#{bypass.port}",
      authorization_servers: ["http://auth.example.com"]
    }

    Bypass.expect(bypass, "GET", "/.well-known/oauth-protected-resource", fn conn ->
      conn |> put_resp_content_type("application/json") |> resp(200, Jason.encode!(metadata))
    end)

    assert {:ok, result} = OAuth2Discovery.discover_resource_metadata("http://localhost:#{bypass.port}")
    assert result.resource == metadata.resource
    assert result.authorization_servers == metadata.authorization_servers
  end

  test "discover_resource_metadata/1 discards mismatched resource" do
    bypass = Bypass.open()
    bad_metadata = %ProtectedResourceMetadata{
      resource: "http://bad.example.com",
      authorization_servers: ["http://auth.example.com"]
    }

    Bypass.expect(bypass, "GET", "/.well-known/oauth-protected-resource", fn conn ->
      conn |> put_resp_content_type("application/json") |> resp(200, Jason.encode!(bad_metadata))
    end)

    assert {:error, :mismatched_resource} = OAuth2Discovery.discover_resource_metadata("http://localhost:#{bypass.port}")
  end
end
