defmodule ADK.Auth.CredentialManager do
  @moduledoc """
  Stateless orchestrator for the full OAuth2 / credential lifecycle.

  Mirrors Python ADK's `CredentialManager` but as pure functions.
  The lifecycle is: **load → exchange → refresh → save**.

  ## Usage

      alias ADK.Auth.{Credential, CredentialManager, InMemoryStore}

      # Create a store process
      {:ok, store} = InMemoryStore.start_link()

      # Initial credential (has auth_code, awaiting exchange)
      cred = Credential.oauth2_with_code(
        "client-id",
        "client-secret",
        "auth-code-from-callback",
        token_endpoint: "https://oauth.example.com/token"
      )

      # The manager will exchange, save, and return the ready credential
      {:ok, ready} = CredentialManager.get_credential("github", cred, server: store)
      # => %Credential{type: :oauth2, access_token: "gho_...", refresh_token: "ghr_..."}

      # On next call: loads from store, refreshes if near-expired
      {:ok, ready} = CredentialManager.get_credential("github", cred, server: store)

  ## Options

  - `:server` — the credential store PID or name (passed to `InMemoryStore`)
  - `:store_mod` — module implementing `ADK.Auth.CredentialStore` (default: `ADK.Auth.InMemoryStore`)
  - `:redirect_uri` — used during auth code exchange
  - `:refresh_buffer` — seconds before expiry to proactively refresh (default: 300)
  - `:http_opts` — extra options forwarded to `Req.post/2`
  """

  alias ADK.Auth.{Credential, OAuth2}

  @default_refresh_buffer 300

  @doc """
  Get a ready credential by name, running exchange/refresh as needed.

  Steps:
  1. If credential is a simple type (api_key, http_bearer) → return immediately
  2. Try loading from the credential store
  3. If loaded → check expiry → refresh if needed → save if refreshed → return
  4. If not loaded and credential needs exchange → exchange → save → return
  5. If not loaded and credential is client_credentials-capable → exchange → save → return
  6. Otherwise → `:needs_auth` (user must re-authenticate)

  ## Returns

  - `{:ok, credential}` — ready-to-use credential
  - `:needs_auth` — no stored credential and no auth code; user must authenticate
  - `{:error, reason}` — exchange/refresh/store failure
  """
  @spec get_credential(String.t(), Credential.t(), keyword()) ::
          {:ok, Credential.t()} | :needs_auth | {:error, term()}
  def get_credential(credential_name, raw_cred, opts \\ []) do
    # Simple credentials don't need exchange/refresh
    if simple_credential?(raw_cred) do
      {:ok, raw_cred}
    else
      resolve_credential(credential_name, raw_cred, opts)
    end
  end

  @doc """
  Store a credential under a name. Convenience wrapper around the store module.
  """
  @spec save_credential(String.t(), Credential.t(), keyword()) :: :ok | {:error, term()}
  def save_credential(credential_name, cred, opts \\ []) do
    {store_mod, store_opts} = store_config(opts)
    store_mod.put(credential_name, cred, store_opts)
  end

  @doc """
  Delete a credential from the store.
  """
  @spec delete_credential(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_credential(credential_name, opts \\ []) do
    {store_mod, store_opts} = store_config(opts)
    store_mod.delete(credential_name, store_opts)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve_credential(name, raw_cred, opts) do
    {store_mod, store_opts} = store_config(opts)
    refresh_buffer = Keyword.get(opts, :refresh_buffer, @default_refresh_buffer)

    case store_mod.get(name, store_opts) do
      {:ok, stored_cred} ->
        # Have a stored credential — refresh if near-expiry
        handle_stored_credential(
          name,
          stored_cred,
          raw_cred,
          opts,
          store_mod,
          store_opts,
          refresh_buffer
        )

      :not_found ->
        # No stored credential — try to obtain one
        handle_missing_credential(name, raw_cred, opts, store_mod, store_opts)

      {:error, reason} ->
        {:error, {:store_error, reason}}
    end
  end

  defp handle_stored_credential(
         name,
         stored_cred,
         _raw_cred,
         opts,
         store_mod,
         store_opts,
         refresh_buffer
       ) do
    if OAuth2.expires_soon?(stored_cred, refresh_buffer) and OAuth2.refreshable?(stored_cred) do
      http_opts = Keyword.get(opts, :http_opts, [])

      case OAuth2.refresh_token(stored_cred, http_opts: http_opts) do
        {:ok, refreshed} ->
          store_mod.put(name, refreshed, store_opts)
          {:ok, refreshed}

        {:error, reason} ->
          # Refresh failed — return what we have if not actually expired
          if OAuth2.expired?(stored_cred) do
            {:error, {:refresh_failed, reason}}
          else
            {:ok, stored_cred}
          end
      end
    else
      {:ok, stored_cred}
    end
  end

  defp handle_missing_credential(name, raw_cred, opts, store_mod, store_opts) do
    http_opts = Keyword.get(opts, :http_opts, [])
    redirect_uri = Keyword.get(opts, :redirect_uri, "")

    cond do
      raw_cred.type == :service_account ->
        case ADK.Auth.Google.from_service_account_info(raw_cred.service_account_key, raw_cred.scopes) do
          {:ok, %{token: token}} ->
            now = System.system_time(:second)
            exchanged = %{raw_cred | 
              access_token: token,
              metadata: Map.merge(raw_cred.metadata, %{
                "expires_at" => now + 3600,
                "token_type" => "Bearer",
                "refreshed_at" => now
              })
            }
            store_mod.put(name, exchanged, store_opts)
            {:ok, exchanged}

          {:error, _} = err ->
            err
        end

      OAuth2.needs_exchange?(raw_cred) ->
        # Has auth_code → exchange for tokens
        case OAuth2.exchange_code(raw_cred, redirect_uri: redirect_uri, http_opts: http_opts) do
          {:ok, exchanged} ->
            store_mod.put(name, exchanged, store_opts)
            {:ok, exchanged}

          {:error, _} = err ->
            err
        end

      client_credentials_capable?(raw_cred) ->
        # Client credentials flow — no user needed
        case OAuth2.client_credentials(raw_cred, http_opts: http_opts) do
          {:ok, exchanged} ->
            store_mod.put(name, exchanged, store_opts)
            {:ok, exchanged}

          {:error, _} = err ->
            err
        end

      true ->
        :needs_auth
    end
  end

  @spec simple_credential?(Credential.t()) :: boolean()
  defp simple_credential?(%Credential{type: type})
       when type in [:api_key, :http_bearer],
       do: true

  defp simple_credential?(_), do: false

  @spec client_credentials_capable?(Credential.t()) :: boolean()
  defp client_credentials_capable?(%Credential{
         client_id: id,
         client_secret: secret,
         token_endpoint: ep
       })
       when is_binary(id) and is_binary(secret) and is_binary(ep),
       do: true

  defp client_credentials_capable?(_), do: false

  defp store_config(opts) do
    store_mod = Keyword.get(opts, :store_mod, ADK.Auth.InMemoryStore)
    # Pass through server and any other store opts
    store_opts = Keyword.take(opts, [:server])
    {store_mod, store_opts}
  end
end
