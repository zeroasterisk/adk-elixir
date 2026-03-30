defmodule ADK.Tool.OpenApiTool.Auth.AuthHelpers do
  @moduledoc """
  Authentication helpers for OpenAPI tools.
  Mirrors Python ADK's `google.adk.tools.openapi_tool.auth.auth_helpers`.
  """

  alias ADK.Auth.Credential

  @internal_auth_prefix "_auth_prefix_vaf_"

  def token_to_scheme_credential(type, location, name, credential_value \\ nil)

  def token_to_scheme_credential("apikey", location, name, credential_value) do
    in_ =
      case location do
        "header" -> "header"
        "query" -> "query"
        "cookie" -> "cookie"
        _ -> raise ArgumentError, "Invalid location for apiKey: #{location}"
      end

    scheme = %{"type" => "apiKey", "in" => in_, "name" => name}
    cred = if credential_value, do: Credential.api_key(credential_value), else: nil
    {scheme, cred}
  end

  def token_to_scheme_credential("oauth2Token", _location, _name, credential_value) do
    scheme = %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
    cred = if credential_value, do: Credential.http_bearer(credential_value), else: nil
    {scheme, cred}
  end

  def token_to_scheme_credential(type, _location, _name, _credential_value) do
    raise ArgumentError, "Invalid security scheme type: #{type}"
  end

  def service_account_dict_to_scheme_credential(config, scopes) do
    scheme = %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
    cred = Credential.service_account(config, scopes: scopes)
    {scheme, cred}
  end

  def service_account_scheme_credential(%Credential{type: :service_account} = config) do
    scheme = %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
    {scheme, config}
  end

  def openid_dict_to_scheme_credential(config_dict, scopes, credential_dict) do
    # config_dict must include authorization_endpoint and token_endpoint
    config_dict = Map.put(config_dict, "scopes", scopes)
    config_dict = Map.put_new(config_dict, "openIdConnectUrl", "")

    required_keys = ["authorization_endpoint", "token_endpoint"]
    missing_config = Enum.filter(required_keys, fn k -> not Map.has_key?(config_dict, k) end)

    if missing_config != [] do
      raise ArgumentError,
            "Invalid OpenID Connect configuration: missing #{Enum.join(missing_config, ", ")}"
    end

    scheme = Map.merge(%{"type" => "openIdConnect"}, config_dict)

    # Attempt to adjust credential_dict if this is a key downloaded from Google OAuth config
    credential_dict =
      if map_size(credential_dict) == 1 do
        {_key, value} = Enum.at(credential_dict, 0)

        if is_map(value) and Map.has_key?(value, "client_id") and
             Map.has_key?(value, "client_secret") do
          value
        else
          credential_dict
        end
      else
        credential_dict
      end

    required_cred = ["client_id", "client_secret"]
    missing_cred = Enum.filter(required_cred, fn k -> not Map.has_key?(credential_dict, k) end)

    if missing_cred != [] do
      raise ArgumentError,
            "Missing required fields in credential_dict: #{Enum.join(missing_cred, ", ")}"
    end

    cred =
      Credential.open_id_connect(
        nil,
        client_id: credential_dict["client_id"],
        client_secret: credential_dict["client_secret"]
      )

    cred =
      if Map.has_key?(credential_dict, "redirect_uri") do
        %{
          cred
          | metadata: Map.put(cred.metadata, "redirect_uri", credential_dict["redirect_uri"])
        }
      else
        cred
      end

    {scheme, cred}
  end

  def openid_url_to_scheme_credential(openid_url, scopes, credential_dict) do
    case Req.get(openid_url, receive_timeout: 10_000, retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        config_dict =
          case body do
            b when is_map(b) ->
              b

            b when is_binary(b) ->
              case Jason.decode(b) do
                {:ok, decoded} ->
                  decoded

                {:error, _} ->
                  raise ArgumentError,
                        "Invalid JSON response from OpenID configuration endpoint #{openid_url}: Invalid JSON"
              end
          end

        config_dict = Map.put(config_dict, "openIdConnectUrl", openid_url)
        openid_dict_to_scheme_credential(config_dict, scopes, credential_dict)

      {:ok, %{status: status}} ->
        raise ArgumentError,
              "Failed to fetch OpenID configuration from #{openid_url}: HTTP #{status}"

      {:error, %Jason.DecodeError{} = err} ->
        raise ArgumentError,
              "Invalid JSON response from OpenID configuration endpoint #{openid_url}: #{inspect(err)}"

      {:error, reason} ->
        raise ArgumentError,
              "Failed to fetch OpenID configuration from #{openid_url}: #{inspect(reason)}"
    end
  end

  def credential_to_param(auth_scheme, auth_credential)

  def credential_to_param(_scheme, nil), do: {nil, nil}

  def credential_to_param(
        %{"type" => "apiKey"} = auth_scheme,
        %Credential{type: :api_key, api_key: api_key} = _cred
      )
      when not is_nil(api_key) do
    param_name = Map.get(auth_scheme, "name", "")
    python_name = @internal_auth_prefix <> param_name
    param_location = Map.get(auth_scheme, "in")

    param = %{
      original_name: param_name,
      param_location: param_location,
      py_name: python_name,
      description: Map.get(auth_scheme, "description", ""),
      param_schema: %{"type" => "string"}
    }

    kwargs = %{python_name => api_key}
    {param, kwargs}
  end

  def credential_to_param(%{"type" => "http"}, %Credential{
        type: :http_bearer,
        metadata: %{"basic" => true}
      }) do
    raise ArgumentError, "Basic Authentication is not supported."
  end

  def credential_to_param(
        %{"type" => "http"} = auth_scheme,
        %Credential{type: :http_bearer, access_token: token} = _cred
      )
      when not is_nil(token) do
    param = %{
      original_name: "Authorization",
      param_location: "header",
      py_name: @internal_auth_prefix <> "Authorization",
      description: Map.get(auth_scheme, "description", "Bearer token"),
      param_schema: %{"type" => "string"}
    }

    kwargs = %{(@internal_auth_prefix <> "Authorization") => "Bearer #{token}"}
    {param, kwargs}
  end

  def credential_to_param(%{"type" => "http"}, %Credential{type: :http_bearer, access_token: nil}) do
    raise ArgumentError, "Invalid HTTP auth credentials"
  end

  def credential_to_param(
        %{"type" => "oauth2"} = auth_scheme,
        %Credential{type: :http_bearer, access_token: token} = _cred
      )
      when not is_nil(token) do
    param = %{
      original_name: "Authorization",
      param_location: "header",
      py_name: @internal_auth_prefix <> "Authorization",
      description: Map.get(auth_scheme, "description", "Bearer token"),
      param_schema: %{"type" => "string"}
    }

    kwargs = %{(@internal_auth_prefix <> "Authorization") => "Bearer #{token}"}
    {param, kwargs}
  end

  def credential_to_param(
        %{"type" => "openIdConnect"} = auth_scheme,
        %Credential{type: :http_bearer, access_token: token} = _cred
      )
      when not is_nil(token) do
    param = %{
      original_name: "Authorization",
      param_location: "header",
      py_name: @internal_auth_prefix <> "Authorization",
      description: Map.get(auth_scheme, "description", "Bearer token"),
      param_schema: %{"type" => "string"}
    }

    kwargs = %{(@internal_auth_prefix <> "Authorization") => "Bearer #{token}"}
    {param, kwargs}
  end

  def credential_to_param(%{"type" => "oauth2"}, _cred), do: {nil, nil}
  def credential_to_param(%{"type" => "openIdConnect"}, _cred), do: {nil, nil}

  def credential_to_param(_scheme, _cred) do
    raise ArgumentError, "Invalid security scheme and credential combination"
  end

  def dict_to_auth_scheme(data) do
    unless Map.has_key?(data, "type") do
      raise ArgumentError, "Missing 'type' field in security scheme dictionary."
    end

    security_type = data["type"]

    case security_type do
      "apiKey" ->
        unless Map.has_key?(data, "name") and Map.has_key?(data, "in") do
          raise ArgumentError, "Invalid security scheme data"
        end

        data

      "http" ->
        data

      "oauth2" ->
        data

      "openIdConnect" ->
        data

      _ ->
        raise ArgumentError, "Invalid security scheme type: #{security_type}"
    end
  end
end
