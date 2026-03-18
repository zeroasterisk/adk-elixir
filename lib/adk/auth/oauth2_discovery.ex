defmodule ADK.Auth.OAuth2Discovery do
  @moduledoc """
  Discovers OAuth2 metadata for authorization servers and protected resources.
  """

  alias ADK.Auth.OAuth2.{AuthorizationServerMetadata, ProtectedResourceMetadata}

  @timeout 5000

  def discover_auth_server_metadata(issuer) do
    oauth_server_config_url = URI.parse(issuer) |> Map.put(:path, "/.well-known/oauth-authorization-server") |> URI.to_string()
    openid_config_url = URI.parse(issuer) |> Map.put(:path, "/.well-known/openid-configuration") |> URI.to_string()

    case fetch_and_decode(oauth_server_config_url) do
      {:ok, metadata} ->
        if metadata["issuer"] == issuer do
          {:ok, struct(AuthorizationServerMetadata, metadata)}
        else
          case fetch_and_decode(openid_config_url) do
            {:ok, metadata} ->
              if metadata["issuer"] == issuer do
                {:ok, struct(AuthorizationServerMetadata, metadata)}
              else
                {:error, :mismatched_issuer}
              end
            error -> error
          end
        end
      _error ->
        case fetch_and_decode(openid_config_url) do
          {:ok, metadata} ->
            if metadata["issuer"] == issuer do
              {:ok, struct(AuthorizationServerMetadata, metadata)}
            else
              {:error, :mismatched_issuer}
            end
          error -> error
        end
    end
  end

  def discover_resource_metadata(resource) do
    url = URI.parse(resource) |> Map.put(:path, "/.well-known/oauth-protected-resource") |> URI.to_string()
    case fetch_and_decode(url) do
      {:ok, metadata} ->
        if metadata["resource"] == resource do
          {:ok, struct(ProtectedResourceMetadata, metadata)}
        else
          {:error, :mismatched_resource}
        end
      error -> error
    end
  end

  defp fetch_and_decode(url) do
    case Req.get(url, timeout: @timeout) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          _ -> {:error, :invalid_json}
        end
      _ -> {:error, :http_error}
    end
  end
end
