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

  # Default implementation using Req and :public_key.

  @impl true
  def default_credentials(_scopes), do: {:error, :not_implemented}

  @impl true
  def fetch_id_token(_audience), do: {:error, :not_implemented}

  @impl true
  def from_service_account_info(key_info, scopes) do
    now = System.system_time(:second)

    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)

    claims = Base.url_encode64(
      Jason.encode!(%{
        "iss" => key_info["client_email"],
        "scope" => Enum.join(scopes, " "),
        "aud" => key_info["token_uri"] || "https://oauth2.googleapis.com/token",
        "iat" => now,
        "exp" => now + 3600
      }),
      padding: false
    )

    signing_input = "#{header}.#{claims}"

    case :public_key.pem_decode(key_info["private_key"]) do
      [entry] ->
        key = :public_key.pem_entry_decode(entry)
        signature = :public_key.sign(signing_input, :sha256, key)
        sig_b64 = Base.url_encode64(signature, padding: false)

        jwt = "#{signing_input}.#{sig_b64}"

        case Req.post(key_info["token_uri"] || "https://oauth2.googleapis.com/token",
               form: [
                 grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
                 assertion: jwt
               ]
             ) do
          {:ok, %{status: 200, body: body}} ->
            {:ok, %{token: body["access_token"]}}

          {:ok, %{status: status, body: body}} ->
            {:error, {:token_error, status, body}}

          {:error, reason} ->
            {:error, {:http_error, reason}}
        end

      _ ->
        {:error, :invalid_private_key}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def from_service_account_info_id_token(_key_info, _audience), do: {:error, :not_implemented}
end
