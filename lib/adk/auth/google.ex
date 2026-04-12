defmodule ADK.Auth.Google do
  @moduledoc """
  Google Authentication integration behavior for ADK.
  Allows fetching application default credentials or explicit service account tokens.
  """

  @callback default_credentials(scopes :: [String.t()]) ::
              {:ok, %{token: String.t(), quota_project_id: String.t() | nil}} | {:error, term()}

  @callback fetch_id_token(audience :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @callback from_service_account_info(key_info :: map(), scopes :: [String.t()]) ::
              {:ok, %{token: String.t()}} | {:error, term()}

  @callback from_service_account_info_id_token(key_info :: map(), audience :: String.t()) ::
              {:ok, %{token: String.t()}} | {:error, term()}

  def client do
    ADK.Config.google_auth_client()
  end

  def default_credentials(scopes) do
    client().default_credentials(scopes)
  end

  def fetch_id_token(audience) do
    client().fetch_id_token(audience)
  end

  def from_service_account_info(key_info, scopes) do
    client().from_service_account_info(key_info, scopes)
  end

  def from_service_account_info_id_token(key_info, audience) do
    client().from_service_account_info_id_token(key_info, audience)
  end
end

defmodule ADK.Auth.Google.DefaultClient do
  @moduledoc false
  @behaviour ADK.Auth.Google

  # A real implementation would integrate with Goth or google_api_auth.
  # For parity, we leave these returning not_implemented in production,
  # or you can implement them properly using Req if desired.

  @impl true
  def default_credentials(_scopes), do: {:error, :not_implemented}

  @impl true
  def fetch_id_token(_audience), do: {:error, :not_implemented}

  @impl true
  def from_service_account_info(_key_info, _scopes), do: {:error, :not_implemented}

  @impl true
  def from_service_account_info_id_token(_key_info, _audience), do: {:error, :not_implemented}
end
