defmodule ADK.Auth.Handler do
  @moduledoc """
  Orchestrates the OAuth2 authentication flow for ADK tools.

  Mirrors Python ADK's `AuthHandler` — validates auth config, generates
  authorization URIs, retrieves/stores auth responses in session state,
  and exchanges authorization codes for tokens.

  ## Usage

      config = ADK.Auth.Config.new(
        credential_type: :oauth2,
        scopes: ["read", "write"],
        raw_credential: raw_cred,
        exchanged_credential: exchanged_cred
      )

      handler = ADK.Auth.Handler.new(config)

      # Generate auth request (validates + builds auth URI if needed)
      {:ok, updated_config} = ADK.Auth.Handler.generate_auth_request(handler)

      # After user authorizes, get response from state
      credential = ADK.Auth.Handler.get_auth_response(handler, state)

      # Parse and store the auth response
      :ok = ADK.Auth.Handler.parse_and_store_auth_response(handler, state)

  OAuth2-specific transient fields (auth_uri, state, redirect_uri,
  authorization_endpoint, audience) are stored in the credential's
  `metadata` map.
  """

  alias ADK.Auth.{Config, Credential, OAuth2}

  @type t :: %__MODULE__{auth_config: Config.t()}

  defstruct [:auth_config]

  @oauth_types [:oauth2, :open_id_connect]

  # ---------------------------------------------------------------------------
  # Constructor
  # ---------------------------------------------------------------------------

  @doc "Create a new handler from an auth config."
  @spec new(Config.t()) :: t()
  def new(%Config{} = config), do: %__MODULE__{auth_config: config}

  # ---------------------------------------------------------------------------
  # Generate Auth URI
  # ---------------------------------------------------------------------------

  @doc """
  Generates an OAuth2 authorization URL from the config's raw credential.

  Reads `authorization_endpoint`, `redirect_uri`, and `audience` from
  the credential's metadata. Scopes come from the config (falling back
  to the credential's scopes).

  Returns an updated credential with `auth_uri` and `state` in metadata.
  """
  @spec generate_auth_uri(t()) :: Credential.t()
  def generate_auth_uri(%__MODULE__{auth_config: config}) do
    cred = config.raw_credential
    meta = cred.metadata || %{}

    authorization_endpoint = meta["authorization_endpoint"]
    redirect_uri = meta["redirect_uri"]
    audience = meta["audience"]

    scopes =
      case config.scopes do
        s when is_list(s) and s != [] -> s
        _ -> cred.scopes || []
      end

    state = generate_state()

    params =
      [
        {"client_id", cred.client_id},
        {"redirect_uri", redirect_uri},
        {"scope", Enum.join(scopes, " ")},
        {"response_type", "code"},
        {"access_type", "offline"},
        {"prompt", "consent"}
      ]
      |> maybe_append("audience", audience)

    auth_uri = authorization_endpoint <> "?" <> URI.encode_query(params)

    updated_metadata =
      meta
      |> Map.put("auth_uri", auth_uri)
      |> Map.put("state", state)

    %{cred | metadata: updated_metadata}
  end

  # ---------------------------------------------------------------------------
  # Generate Auth Request
  # ---------------------------------------------------------------------------

  @doc """
  Validates the auth config and returns an updated config with an auth URI.

  Behaviour:
  - Non-OAuth schemes (`:api_key`, `:http_bearer`, etc.) → returns config as-is
  - If `exchanged_credential` already has an `auth_uri` → returns as-is
  - Missing `raw_credential` → raises `ArgumentError`
  - Missing OAuth2 fields in raw_credential → raises `ArgumentError`
  - Missing `client_id`/`client_secret` → raises `ArgumentError`
  - If `raw_credential` already has an `auth_uri` → copies it to exchanged
  - Otherwise → generates a new auth URI via `generate_auth_uri/1`
  """
  @spec generate_auth_request(t()) :: Config.t()
  def generate_auth_request(%__MODULE__{auth_config: config} = handler) do
    # Non-OAuth scheme → passthrough
    unless config.credential_type in @oauth_types do
      return_config_copy(config)
    else
      # auth_uri already in exchanged credential
      if has_auth_uri?(config.exchanged_credential) do
        return_config_copy(config)
      else
        # Validate raw_credential exists
        unless config.raw_credential do
          raise ArgumentError,
                "Auth scheme #{config.credential_type} requires auth_credential."
        end

        # Validate raw_credential is OAuth type with required fields
        unless oauth_capable?(config.raw_credential) do
          raise ArgumentError,
                "Auth scheme #{config.credential_type} requires oauth2 in auth_credential."
        end

        # auth_uri already in raw credential
        if has_auth_uri?(config.raw_credential) do
          %Config{
            config
            | exchanged_credential: deep_copy_credential(config.raw_credential)
          }
        else
          # Validate client credentials
          unless config.raw_credential.client_id && config.raw_credential.client_secret do
            raise ArgumentError,
                  "Auth scheme #{config.credential_type} requires both client_id and client_secret in auth_credential."
          end

          # Generate new auth URI
          exchanged = generate_auth_uri(handler)

          %Config{config | exchanged_credential: exchanged}
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Get Auth Response
  # ---------------------------------------------------------------------------

  @doc """
  Retrieves a stored auth response from session state.

  Looks up `"temp:" <> credential_key` in the state map.
  Returns the credential or `nil` if not found.
  """
  @spec get_auth_response(t(), map()) :: Credential.t() | nil
  def get_auth_response(%__MODULE__{auth_config: config}, state) do
    credential_key = Config.credential_key(config)
    Map.get(state, "temp:" <> credential_key, nil)
  end

  # ---------------------------------------------------------------------------
  # Parse and Store Auth Response
  # ---------------------------------------------------------------------------

  @doc """
  Stores the exchanged credential in session state.

  For non-OAuth schemes, stores the exchanged credential directly.
  For OAuth schemes, calls `exchange_auth_token/1` first, then stores.

  Returns `{:ok, updated_state}`.
  """
  @spec parse_and_store_auth_response(t(), map()) :: {:ok, map()}
  def parse_and_store_auth_response(%__MODULE__{auth_config: config} = handler, state) do
    credential_key = "temp:" <> Config.credential_key(config)

    if config.credential_type in @oauth_types do
      {:ok, exchanged} = exchange_auth_token(handler)
      {:ok, Map.put(state, credential_key, exchanged)}
    else
      {:ok, Map.put(state, credential_key, config.exchanged_credential)}
    end
  end

  # ---------------------------------------------------------------------------
  # Exchange Auth Token
  # ---------------------------------------------------------------------------

  @doc """
  Exchanges an authorization code for access/refresh tokens.

  Returns `{:ok, credential}`. Falls back to returning the existing
  credential as-is when:
  - The credential already has an `access_token`
  - The credential is not OAuth type
  - Missing `token_endpoint`
  - Missing `client_id`/`client_secret`/`auth_code`
  """
  @spec exchange_auth_token(t()) :: {:ok, Credential.t()}
  def exchange_auth_token(%__MODULE__{auth_config: config}) do
    cred = config.exchanged_credential

    cond do
      # Non-OAuth scheme
      config.credential_type not in @oauth_types ->
        {:ok, cred}

      # No exchanged credential or missing OAuth fields
      is_nil(cred) ->
        {:ok, cred}

      # Already has access_token
      is_binary(cred.access_token) and cred.access_token != "" ->
        {:ok, cred}

      # Missing token_endpoint
      is_nil(cred.token_endpoint) or cred.token_endpoint == "" ->
        {:ok, cred}

      # Missing client credentials or auth_code
      is_nil(cred.client_id) or is_nil(cred.client_secret) ->
        {:ok, cred}

      is_nil(cred.auth_code) ->
        {:ok, cred}

      # All good — exchange
      true ->
        redirect_uri = (cred.metadata || %{})["redirect_uri"] || ""

        case OAuth2.exchange_code(cred, redirect_uri: redirect_uri) do
          {:ok, exchanged} -> {:ok, exchanged}
          {:error, _reason} -> {:ok, cred}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp has_auth_uri?(nil), do: false

  defp has_auth_uri?(%Credential{metadata: meta}) when is_map(meta) do
    case meta["auth_uri"] do
      uri when is_binary(uri) and uri != "" -> true
      _ -> false
    end
  end

  defp has_auth_uri?(_), do: false

  defp oauth_capable?(%Credential{type: type}) when type in @oauth_types, do: true
  defp oauth_capable?(%Credential{client_id: id}) when is_binary(id), do: true
  defp oauth_capable?(_), do: false

  defp return_config_copy(config) do
    # Return a copy — Elixir structs are immutable, so this is already safe
    config
  end

  defp deep_copy_credential(%Credential{} = cred) do
    %{cred | metadata: Map.new(cred.metadata || %{})}
  end

  defp generate_state do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp maybe_append(params, _key, nil), do: params
  defp maybe_append(params, _key, ""), do: params
  defp maybe_append(params, key, value), do: params ++ [{key, value}]
end
