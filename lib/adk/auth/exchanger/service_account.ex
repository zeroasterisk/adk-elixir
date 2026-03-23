defmodule ADK.Auth.Exchanger.ServiceAccount do
  @moduledoc """
  Exchanges Google Service Account credentials for an HTTP Bearer token.
  Mirrors Python ADK's `ServiceAccountCredentialExchanger`.
  """
  @behaviour ADK.Auth.Exchanger

  alias ADK.Auth.Credential
  alias ADK.Auth.Google

  @default_scopes ["https://www.googleapis.com/auth/cloud-platform"]

  @impl true
  def exchange(nil, _scheme) do
    {:error, "Service account credentials are missing"}
  end

  def exchange(%Credential{type: :service_account} = cred, _scheme) do
    # Read service account config from metadata
    use_adc? = Map.get(cred.metadata, :use_default_credential, false)
    use_id_token? = Map.get(cred.metadata, :use_id_token, false)
    audience = Map.get(cred.metadata, :audience)

    # Validation mimicking Pydantic model validators
    cond do
      use_id_token? and (audience == nil or audience == "") ->
        {:error, "audience is required when use_id_token is True"}

      not use_adc? and (cred.service_account_key == nil or cred.service_account_key == %{}) ->
        {:error, "service_account_credential is required"}

      true ->
        scopes =
          case cred.scopes do
            nil -> @default_scopes
            [] -> @default_scopes
            other -> other
          end

        # Do exchange based on config
        cond do
          use_adc? ->
            fetch_adc_token(scopes, use_id_token?, audience)

          cred.service_account_key != nil ->
            if scopes == @default_scopes and cred.scopes == [] and not use_id_token? do
              {:error, "scopes are required"}
            else
              fetch_explicit_token(cred.service_account_key, scopes, use_id_token?, audience)
            end

          true ->
            {:error, "Service account credentials are missing"}
        end
    end
  end

  def exchange(%Credential{}, _scheme) do
    {:error, "Service account credentials are missing"}
  end

  # --- Fetch Tokens ---

  defp fetch_adc_token(scopes, use_id_token?, audience) do
    if use_id_token? do
      case Google.fetch_id_token(audience) do
        {:ok, id_token} ->
          {:ok, Credential.http_bearer(id_token)}

        {:error, error} ->
          {:error, "Failed to exchange service account for ID token: #{inspect(error)}"}
      end
    else
      case Google.default_credentials(scopes) do
        {:ok, %{token: token, quota_project_id: quota_project_id}} ->
          metadata =
            if quota_project_id,
              do: %{"additional_headers" => %{"x-goog-user-project" => quota_project_id}},
              else: %{}

          {:ok, Credential.http_bearer(token, metadata: metadata)}

        {:error, error} ->
          {:error, "Failed to exchange service account token: #{inspect(error)}"}
      end
    end
  end

  defp fetch_explicit_token(key_info, scopes, use_id_token?, audience) do
    if use_id_token? do
      case Google.from_service_account_info_id_token(key_info, audience) do
        {:ok, %{token: id_token}} ->
          {:ok, Credential.http_bearer(id_token)}

        {:error, error} ->
          {:error, "Failed to exchange service account for ID token: #{inspect(error)}"}
      end
    else
      case Google.from_service_account_info(key_info, scopes) do
        {:ok, %{token: token}} ->
          {:ok, Credential.http_bearer(token)}

        {:error, error} ->
          {:error, "Failed to exchange service account token: #{inspect(error)}"}
      end
    end
  end
end
