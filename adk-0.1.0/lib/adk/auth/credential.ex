defmodule ADK.Auth.Credential do
  @moduledoc """
  Represents an authentication credential.

  Mirrors Python ADK's `AuthCredential` — supports API key, OAuth2,
  service account, HTTP bearer, and OpenID Connect credential types.

  ## Examples

      iex> ADK.Auth.Credential.api_key("my-secret-key")
      %ADK.Auth.Credential{type: :api_key, api_key: "my-secret-key"}

      iex> ADK.Auth.Credential.oauth2("token123", refresh_token: "ref456")
      %ADK.Auth.Credential{type: :oauth2, access_token: "token123", refresh_token: "ref456"}
  """

  @type credential_type :: :api_key | :oauth2 | :service_account | :http_bearer | :open_id_connect

  @type t :: %__MODULE__{
          type: credential_type(),
          api_key: String.t() | nil,
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          token_endpoint: String.t() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          scopes: [String.t()],
          service_account_key: map() | nil,
          metadata: map()
        }

  defstruct [
    :type,
    :api_key,
    :access_token,
    :refresh_token,
    :token_endpoint,
    :client_id,
    :client_secret,
    :service_account_key,
    scopes: [],
    metadata: %{}
  ]

  @doc "Create an API key credential."
  @spec api_key(String.t(), keyword()) :: t()
  def api_key(key, opts \\ []) do
    %__MODULE__{
      type: :api_key,
      api_key: key,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Create an OAuth2 credential."
  @spec oauth2(String.t(), keyword()) :: t()
  def oauth2(access_token, opts \\ []) do
    %__MODULE__{
      type: :oauth2,
      access_token: access_token,
      refresh_token: Keyword.get(opts, :refresh_token),
      token_endpoint: Keyword.get(opts, :token_endpoint),
      client_id: Keyword.get(opts, :client_id),
      client_secret: Keyword.get(opts, :client_secret),
      scopes: Keyword.get(opts, :scopes, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Create an HTTP bearer token credential."
  @spec http_bearer(String.t(), keyword()) :: t()
  def http_bearer(token, opts \\ []) do
    %__MODULE__{
      type: :http_bearer,
      access_token: token,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Create a service account credential."
  @spec service_account(map(), keyword()) :: t()
  def service_account(key_data, opts \\ []) do
    %__MODULE__{
      type: :service_account,
      service_account_key: key_data,
      scopes: Keyword.get(opts, :scopes, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Create an OpenID Connect credential."
  @spec open_id_connect(String.t(), keyword()) :: t()
  def open_id_connect(access_token, opts \\ []) do
    %__MODULE__{
      type: :open_id_connect,
      access_token: access_token,
      refresh_token: Keyword.get(opts, :refresh_token),
      token_endpoint: Keyword.get(opts, :token_endpoint),
      client_id: Keyword.get(opts, :client_id),
      client_secret: Keyword.get(opts, :client_secret),
      scopes: Keyword.get(opts, :scopes, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
