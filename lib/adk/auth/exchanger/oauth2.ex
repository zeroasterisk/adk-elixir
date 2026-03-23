defmodule ADK.Auth.Exchanger.OAuth2 do
  @moduledoc """
  Exchanges OAuth2 credentials from authorization responses.

  Mirrors Python ADK's `OAuth2CredentialExchanger`.
  """
  @behaviour ADK.Auth.Exchanger

  alias ADK.Auth.Credential
  alias ADK.Auth.OAuth2

  @impl true
  def exchange(nil, _scheme) do
    {:error, "auth_credential is empty"}
  end

  def exchange(%Credential{} = _cred, nil) do
    {:error, "auth_scheme is required for OAuth2 credential exchange"}
  end

  def exchange(%Credential{} = cred, scheme) do
    case check_scheme_credential_type(scheme, cred) do
      :ok ->
        if cred.type == :http_bearer do
          {:ok, cred}
        else
          do_exchange(cred, scheme)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Validates that the scheme and credential types are valid for OAuth2 exchange.
  Mirrors Python's `_check_scheme_credential_type`.
  """
  def check_scheme_credential_type(_scheme, nil) do
    {:error, "auth_credential is empty. Please create AuthCredential using OAuth2Auth."}
  end

  def check_scheme_credential_type(%{type: type}, _cred) when type not in ["openIdConnect", "oauth2"] do
    {:error, "Invalid security scheme, expect AuthSchemeType.openIdConnect or AuthSchemeType.oauth2 auth scheme, but got #{type}"}
  end

  def check_scheme_credential_type(%{}, %Credential{type: type}) when type not in [:oauth2, :http_bearer, :open_id_connect] do
    {:error, "auth_credential is not configured with oauth2. Please create AuthCredential and set OAuth2Auth."}
  end

  def check_scheme_credential_type(_scheme, _cred) do
    :ok
  end

  @doc """
  Generates an HTTP Bearer credential from an OAuth2 credential with an access token.
  Mirrors Python's `generate_auth_token`.
  """
  def generate_auth_token(%Credential{access_token: token} = cred) when is_binary(token) and token != "" do
    Credential.http_bearer(token, metadata: cred.metadata)
  end

  def generate_auth_token(cred), do: cred

  defp do_exchange(%Credential{access_token: token} = cred, _scheme)
       when is_binary(token) and token != "" do
    {:ok, cred}
  end

  defp do_exchange(%Credential{} = cred, scheme) do
    case determine_grant_type(scheme) do
      :client_credentials ->
        exchange_client_credentials(cred, scheme)

      :authorization_code ->
        exchange_authorization_code(cred, scheme)

      _other ->
        # Unsupported or unknown grant type
        {:ok, cred}
    end
  end

  @doc false
  def determine_grant_type(%{flows: %{client_credentials: _}}) do
    :client_credentials
  end

  def determine_grant_type(%{flows: %{clientCredentials: _}}) do
    :client_credentials
  end

  def determine_grant_type(%{type: "openIdConnect", grant_types_supported: grants}) do
    if "client_credentials" in (grants || []) do
      :client_credentials
    else
      :authorization_code
    end
  end

  def determine_grant_type(%{type: "openIdConnect"}) do
    :authorization_code
  end

  def determine_grant_type(_) do
    nil
  end

  defp exchange_client_credentials(cred, scheme) do
    cred = maybe_inject_token_endpoint(cred, scheme)
    
    http_opts = Map.get(cred.metadata, "http_opts", [])

    case OAuth2.client_credentials(cred, http_opts: http_opts) do
      {:ok, exchanged} -> {:ok, exchanged}
      {:error, _reason} -> {:ok, cred}
    end
  end

  defp exchange_authorization_code(cred, scheme) do
    redirect_uri = normalize_uri(cred.metadata["auth_response_uri"])

    cred = maybe_inject_token_endpoint(cred, scheme)

    http_opts = Map.get(cred.metadata, "http_opts", [])
    opts = if redirect_uri, do: [redirect_uri: redirect_uri, http_opts: http_opts], else: [http_opts: http_opts]

    case OAuth2.exchange_code(cred, opts) do
      {:ok, exchanged} -> {:ok, exchanged}
      {:error, _reason} -> {:ok, cred}
    end
  end

  defp normalize_uri(nil), do: nil

  defp normalize_uri(uri) do
    if String.ends_with?(uri, "#") do
      String.slice(uri, 0..-2//1)
    else
      uri
    end
  end

  defp maybe_inject_token_endpoint(%Credential{token_endpoint: nil} = cred, %{token_endpoint: endpoint})
       when is_binary(endpoint) do
    %{cred | token_endpoint: endpoint}
  end

  defp maybe_inject_token_endpoint(%Credential{token_endpoint: nil} = cred, %{
         flows: %{client_credentials: %{token_endpoint: endpoint}}
       })
       when is_binary(endpoint) do
    %{cred | token_endpoint: endpoint}
  end

  defp maybe_inject_token_endpoint(%Credential{token_endpoint: nil} = cred, %{
         flows: %{clientCredentials: %{tokenUrl: endpoint}}
       })
       when is_binary(endpoint) do
    %{cred | token_endpoint: endpoint}
  end

  defp maybe_inject_token_endpoint(cred, _scheme), do: cred
end
