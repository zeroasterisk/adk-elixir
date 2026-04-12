defmodule ADK.Auth.OAuth2Discovery do
  @moduledoc """
  Discovers OAuth2 metadata for authorization servers and protected resources.
  """

  alias ADK.Auth.OAuth2.{AuthorizationServerMetadata, ProtectedResourceMetadata}

  @timeout 5000

  def discover_auth_server_metadata(issuer) do
    parsed = URI.parse(issuer)
    issuer_path = parsed.path || ""

    path_relative = Path.join(issuer_path, "/.well-known/openid-configuration")

    path_relative =
      if String.starts_with?(path_relative, "/"), do: path_relative, else: "/" <> path_relative

    # RFC 8414: try standard well-known URLs, then path-prefixed variants
    candidate_urls =
      [
        Map.put(parsed, :path, "/.well-known/oauth-authorization-server") |> URI.to_string(),
        Map.put(parsed, :path, "/.well-known/openid-configuration") |> URI.to_string(),
        # Path-relative: issuer_path + /.well-known/...
        Map.put(parsed, :path, path_relative) |> URI.to_string()
      ]
      |> Enum.uniq()

    try_candidates(
      candidate_urls,
      issuer,
      struct_mod: AuthorizationServerMetadata,
      error_tag: :mismatched_issuer,
      match_key: :issuer
    )
  end

  defp try_candidates([url], match_val, opts) do
    struct_mod = Keyword.fetch!(opts, :struct_mod)
    error_tag = Keyword.fetch!(opts, :error_tag)
    match_key = Keyword.fetch!(opts, :match_key)

    case fetch_and_decode(url) do
      {:ok, metadata} ->
        if metadata[match_key] == match_val do
          {:ok, struct(struct_mod, metadata)}
        else
          {:error, error_tag}
        end

      error ->
        error
    end
  end

  defp try_candidates([url | rest], match_val, opts) do
    struct_mod = Keyword.fetch!(opts, :struct_mod)

    match_key = Keyword.fetch!(opts, :match_key)

    case fetch_and_decode(url) do
      {:ok, metadata} ->
        if metadata[match_key] == match_val do
          {:ok, struct(struct_mod, metadata)}
        else
          try_candidates(rest, match_val, opts)
        end

      _error ->
        try_candidates(rest, match_val, opts)
    end
  end

  def discover_resource_metadata(resource) do
    parsed = URI.parse(resource)
    url = Map.put(parsed, :path, "/.well-known/oauth-protected-resource") |> URI.to_string()
    try_candidates([url], resource, struct_mod: ProtectedResourceMetadata, error_tag: :mismatched_resource, match_key: :resource)
  end

  defp fetch_and_decode(url) do
    result =
      try do
        Req.get(url, receive_timeout: @timeout, retry: false)
      rescue
        _ -> {:error, :http_error}
      catch
        _, _ -> {:error, :http_error}
      end

    case result do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, atomize_keys(data)}
          _ -> {:error, :invalid_json}
        end

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, atomize_keys(body)}

      _ ->
        {:error, :http_error}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        try do
          {String.to_existing_atom(k), v}
        rescue
          ArgumentError -> {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end
end
