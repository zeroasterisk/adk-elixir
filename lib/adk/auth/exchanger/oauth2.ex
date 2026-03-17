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

defmodule ADK.Auth.Exchanger.OAuth2 do
  @moduledoc """
  Exchanges OAuth2 credentials from authorization responses.

  Mirrors Python ADK's `OAuth2CredentialExchanger`.
  """
  @behaviour ADK.Auth.Exchanger

  alias ADK.Auth.Credential
  alias ADK.Auth.OAuth2

  @impl true
  def exchange(%Credential{} = _cred, nil) do
    {:error, "auth_scheme is required for OAuth2 credential exchange"}
  end

  def exchange(%Credential{access_token: token} = cred, _scheme)
      when is_binary(token) and token != "" do
    {:ok, cred}
  end

  def exchange(%Credential{} = cred, scheme) do
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
