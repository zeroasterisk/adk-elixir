defmodule ADK.Auth.OAuth2 do
  @derive Jason.Encoder
  defstruct issuer: nil,
            authorization_endpoint: nil,
            token_endpoint: nil,
            scopes_supported: []

  defmodule AuthorizationServerMetadata do
    @moduledoc """
    Represents the metadata of an OAuth2 authorization server.
    """
    @derive Jason.Encoder
    defstruct issuer: nil,
              authorization_endpoint: nil,
              token_endpoint: nil,
              scopes_supported: []
  end

  defmodule ProtectedResourceMetadata do
    @moduledoc """
    Represents the metadata of an OAuth2 protected resource.
    """
    @derive Jason.Encoder
    defstruct resource: nil,
              authorization_servers: []
  end

  @moduledoc """
  Core OAuth2 HTTP operations: authorization URL generation, auth code exchange,
  and token refresh.

  Uses `Req` for HTTP. All functions are stateless — they operate on credential
  structs and return updated structs. The `CredentialManager` orchestrates
  when to call these.

  ## Token Exchange Flow

      # 1. Build authorization URL (redirect user here)
      url = ADK.Auth.OAuth2.authorization_url(%{
        auth_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        client_id: "my-client-id",
        redirect_uri: "https://myapp.com/auth/callback",
        scopes: ["openid", "profile"],
        state: "random-state-string"
      })

      # 2. After redirect, exchange code → tokens
      {:ok, updated_cred} = ADK.Auth.OAuth2.exchange_code(credential, opts)

      # 3. Later, refresh expired token
      {:ok, refreshed_cred} = ADK.Auth.OAuth2.refresh_token(credential, opts)

  ## Token Expiry

  Tokens include `expires_at` (Unix timestamp). Use `expired?/1` or
  `expires_soon?/1` to check before use. The `CredentialManager` handles
  this automatically.
  """

  alias ADK.Auth.Credential

  @type token_response :: %{
          access_token: String.t(),
          token_type: String.t() | nil,
          expires_in: integer() | nil,
          refresh_token: String.t() | nil,
          scope: String.t() | nil,
          id_token: String.t() | nil
        }

  # Default buffer: refresh 5 minutes before actual expiry
  @expiry_buffer_seconds 300

  # ---------------------------------------------------------------------------
  # Authorization URL
  # ---------------------------------------------------------------------------

  @doc """
  Build an OAuth2 authorization URL to redirect the user to.

  Required options:
  - `:auth_endpoint` — the authorization endpoint URL
  - `:client_id` — OAuth2 client ID
  - `:redirect_uri` — callback URL

  Optional options:
  - `:scopes` — list of requested scopes (default: `[]`)
  - `:state` — CSRF state string (default: generated)
  - `:access_type` — `"offline"` to request refresh token (Google-specific)
  - `:extra_params` — map of additional query parameters
  """
  @spec authorization_url(keyword() | map()) :: String.t()
  def authorization_url(opts) when is_list(opts), do: authorization_url(Map.new(opts))

  def authorization_url(%{} = opts) do
    required = [:auth_endpoint, :client_id, :redirect_uri]

    Enum.each(required, fn key ->
      unless Map.has_key?(opts, key) do
        raise ArgumentError, "ADK.Auth.OAuth2.authorization_url/1 requires #{key}"
      end
    end)

    scopes = Map.get(opts, :scopes, [])
    state = Map.get(opts, :state, generate_state())
    extra = Map.get(opts, :extra_params, %{})

    params =
      %{
        response_type: "code",
        client_id: opts.client_id,
        redirect_uri: opts.redirect_uri,
        state: state
      }
      |> maybe_put(:scope, scopes_string(scopes))
      |> maybe_put(:access_type, Map.get(opts, :access_type))
      |> Map.merge(extra)

    opts.auth_endpoint <> "?" <> URI.encode_query(params)
  end

  # ---------------------------------------------------------------------------
  # Auth Code Exchange
  # ---------------------------------------------------------------------------

  @doc """
  Exchange an authorization code for access + refresh tokens.

  The credential must have:
  - `auth_code` — the code received from the OAuth callback
  - `client_id`, `client_secret` — your OAuth app credentials
  - `token_endpoint` — the token URL

  Returns `{:ok, updated_credential}` with `access_token`, `refresh_token`,
  and `expires_at` populated, and `auth_code` cleared.

  Options:
  - `:redirect_uri` — must match the one used in the authorization URL
  - `:http_opts` — extra options passed to `Req.post/2`
  """
  @spec exchange_code(Credential.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, term()}
  def exchange_code(%Credential{} = cred, opts \\ []) do
    with {:ok, _} <- validate_for_exchange(cred) do
      redirect_uri = Keyword.get(opts, :redirect_uri, "")
      http_opts = Keyword.get(opts, :http_opts, [])

      body = %{
        grant_type: "authorization_code",
        code: cred.auth_code,
        client_id: cred.client_id,
        client_secret: cred.client_secret,
        redirect_uri: redirect_uri
      }

      case post_token_request(cred.token_endpoint, body, http_opts) do
        {:ok, token_resp} -> {:ok, apply_token_response(cred, token_resp, clear_auth_code: true)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Perform a client credentials grant (server-to-server, no user).

  The credential must have `client_id`, `client_secret`, and `token_endpoint`.
  Scopes from the credential are used if present.

  Options:
  - `:scopes` — override credential scopes
  - `:http_opts` — extra options passed to `Req.post/2`
  """
  @spec client_credentials(Credential.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, term()}
  def client_credentials(%Credential{} = cred, opts \\ []) do
    unless cred.client_id && cred.client_secret && cred.token_endpoint do
      {:error, :missing_client_credentials}
    else
      scopes = Keyword.get(opts, :scopes, cred.scopes)
      http_opts = Keyword.get(opts, :http_opts, [])

      body =
        %{
          grant_type: "client_credentials",
          client_id: cred.client_id,
          client_secret: cred.client_secret
        }
        |> maybe_put(:scope, scopes_string(scopes))

      case post_token_request(cred.token_endpoint, body, http_opts) do
        {:ok, token_resp} -> {:ok, apply_token_response(cred, token_resp)}
        {:error, _} = err -> err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Token Refresh
  # ---------------------------------------------------------------------------

  @doc """
  Refresh an expired access token using the refresh token.

  The credential must have `refresh_token`, `client_id`, `client_secret`,
  and `token_endpoint`.

  Options:
  - `:scopes` — request specific scopes (optional)
  - `:http_opts` — extra options passed to `Req.post/2`
  """
  @spec refresh_token(Credential.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, term()}
  def refresh_token(%Credential{} = cred, opts \\ []) do
    with {:ok, _} <- validate_for_refresh(cred) do
      scopes = Keyword.get(opts, :scopes, cred.scopes)
      http_opts = Keyword.get(opts, :http_opts, [])

      body =
        %{
          grant_type: "refresh_token",
          refresh_token: cred.refresh_token,
          client_id: cred.client_id,
          client_secret: cred.client_secret
        }
        |> maybe_put(:scope, scopes_string(scopes))

      case post_token_request(cred.token_endpoint, body, http_opts) do
        {:ok, token_resp} ->
          # Some providers don't return a new refresh_token — keep existing
          token_resp = Map.put_new(token_resp, :refresh_token, cred.refresh_token)
          {:ok, apply_token_response(cred, token_resp)}

        {:error, _} = err ->
          err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Expiry Checks
  # ---------------------------------------------------------------------------

  @doc """
  Returns true if the credential's access token has expired.

  Returns false if no `expires_at` is set (assumes still valid).
  """
  @spec expired?(Credential.t()) :: boolean()
  def expired?(%Credential{metadata: %{"expires_at" => expires_at}})
      when is_integer(expires_at) do
    System.system_time(:second) >= expires_at
  end

  def expired?(_), do: false

  @doc """
  Returns true if the credential will expire within the buffer window
  (default: 5 minutes). Proactive refresh to avoid races.
  """
  @spec expires_soon?(Credential.t(), non_neg_integer()) :: boolean()
  def expires_soon?(credential, buffer \\ @expiry_buffer_seconds)

  def expires_soon?(%Credential{metadata: %{"expires_at" => expires_at}}, buffer)
      when is_integer(expires_at) do
    System.system_time(:second) >= expires_at - buffer
  end

  def expires_soon?(_, _), do: false

  @doc """
  Returns true if refresh is possible (credential has refresh_token + endpoint).
  """
  @spec refreshable?(Credential.t()) :: boolean()
  def refreshable?(%Credential{refresh_token: rt, token_endpoint: ep})
      when is_binary(rt) and is_binary(ep),
      do: true

  def refreshable?(_), do: false

  @doc """
  Returns true if the credential needs exchange (has auth_code but no access_token).
  """
  @spec needs_exchange?(Credential.t()) :: boolean()
  def needs_exchange?(%Credential{auth_code: code, access_token: nil})
      when is_binary(code),
      do: true

  def needs_exchange?(_), do: false

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec validate_for_exchange(Credential.t()) :: {:ok, :valid} | {:error, atom()}
  defp validate_for_exchange(%Credential{auth_code: nil}), do: {:error, :missing_auth_code}
  defp validate_for_exchange(%Credential{client_id: nil}), do: {:error, :missing_client_id}
  defp validate_for_exchange(%Credential{client_secret: nil}), do: {:error, :missing_client_secret}
  defp validate_for_exchange(%Credential{token_endpoint: nil}), do: {:error, :missing_token_endpoint}
  defp validate_for_exchange(%Credential{}), do: {:ok, :valid}

  @spec validate_for_refresh(Credential.t()) :: {:ok, :valid} | {:error, atom()}
  defp validate_for_refresh(%Credential{refresh_token: nil}), do: {:error, :missing_refresh_token}
  defp validate_for_refresh(%Credential{client_id: nil}), do: {:error, :missing_client_id}
  defp validate_for_refresh(%Credential{client_secret: nil}), do: {:error, :missing_client_secret}
  defp validate_for_refresh(%Credential{token_endpoint: nil}), do: {:error, :missing_token_endpoint}
  defp validate_for_refresh(%Credential{}), do: {:ok, :valid}

  @spec post_token_request(String.t(), map(), keyword()) ::
          {:ok, token_response()} | {:error, term()}
  defp post_token_request(endpoint, body, http_opts) do
    base_opts = [
      form: body,
      headers: [{"accept", "application/json"}],
      receive_timeout: Keyword.get(http_opts, :receive_timeout, 10_000)
    ]

    opts = Keyword.merge(base_opts, Keyword.drop(http_opts, [:receive_timeout]))

    case Req.post(endpoint, opts) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, parse_token_response(resp_body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_request_failed, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @spec parse_token_response(map() | String.t()) :: token_response()
  defp parse_token_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_token_response(decoded)
      {:error, _} -> %{access_token: nil}
    end
  end

  defp parse_token_response(body) when is_map(body) do
    %{
      access_token: body["access_token"],
      token_type: body["token_type"],
      expires_in: body["expires_in"],
      refresh_token: body["refresh_token"],
      scope: body["scope"],
      id_token: body["id_token"]
    }
  end

  @spec apply_token_response(Credential.t(), token_response(), keyword()) :: Credential.t()
  defp apply_token_response(%Credential{} = cred, token_resp, opts \\ []) do
    now = System.system_time(:second)

    expires_at =
      case token_resp.expires_in do
        n when is_integer(n) and n > 0 -> now + n
        _ -> nil
      end

    metadata =
      cred.metadata
      |> Map.put("token_type", token_resp.token_type)
      |> maybe_put_metadata("expires_at", expires_at)
      |> maybe_put_metadata("scope", token_resp.scope)
      |> maybe_put_metadata("id_token", token_resp.id_token)
      |> maybe_put_metadata("refreshed_at", now)

    updated =
      %{cred | access_token: token_resp.access_token || cred.access_token, metadata: metadata}

    updated =
      if token_resp.refresh_token,
        do: %{updated | refresh_token: token_resp.refresh_token},
        else: updated

    if Keyword.get(opts, :clear_auth_code, false),
      do: %{updated | auth_code: nil},
      else: updated
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp scopes_string([]), do: nil
  defp scopes_string(scopes), do: Enum.join(scopes, " ")

  defp generate_state do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
