defmodule ADK.Tool.BigQuery.CredentialsConfig do
  @moduledoc """
  BigQuery Credentials Configuration for Google API tools (Experimental).

  Please do not use this in production, as it may be deprecated later.
  """

  @enforce_keys []
  defstruct [
    :credentials,
    :external_access_token_key,
    :client_id,
    :client_secret,
    :scopes,
    :_token_cache_key
  ]

  @type t :: %__MODULE__{
          credentials: any() | nil,
          external_access_token_key: String.t() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          scopes: [String.t()] | nil,
          _token_cache_key: String.t() | nil
        }

  @bigquery_scopes [
    "https://www.googleapis.com/auth/bigquery",
    "https://www.googleapis.com/auth/dataplex.read-write"
  ]
  @bigquery_token_cache_key "bigquery_token_cache"

  @doc """
  Creates and validates a new CredentialsConfig.
  """
  def new!(opts \\ []) do
    valid_keys = [:credentials, :external_access_token_key, :client_id, :client_secret, :scopes]

    # Check for invalid properties
    provided_keys = Keyword.keys(opts)
    invalid_keys = provided_keys -- valid_keys

    if length(invalid_keys) > 0 do
      raise ArgumentError, "Invalid properties provided: #{inspect(invalid_keys)}"
    end

    config = struct!(__MODULE__, opts)

    # In Elixir, we don't have google.oauth2.credentials.Credentials. 
    # But if credentials is a map or struct with client_id, client_secret, and scopes, we can extract them.
    config =
      case config.credentials do
        %{client_id: id, client_secret: secret, scopes: sc} ->
          %{config | client_id: id, client_secret: secret, scopes: sc}

        _ ->
          config
      end

    cond do
      config.credentials != nil ->
        # If credentials provided, we check if external token or client_id/secret was ALSO explicitly provided in opts.
        # Since we might have populated client_id/secret from credentials above, we only check the raw opts.
        if Keyword.has_key?(opts, :external_access_token_key) or
             Keyword.has_key?(opts, :client_id) or
             Keyword.has_key?(opts, :client_secret) or
             Keyword.has_key?(opts, :scopes) do
          raise ArgumentError,
                "If credentials are provided, external_access_token_key, client_id, client_secret, and scopes must not be provided."
        else
          set_defaults(config)
        end

      config.external_access_token_key != nil ->
        if config.client_id || config.client_secret || config.scopes do
          raise ArgumentError,
                "If external_access_token_key is provided, client_id, client_secret, and scopes must not be provided."
        else
          set_defaults(config)
        end

      config.client_id == nil or config.client_secret == nil ->
        raise ArgumentError,
              "Must provide one of credentials, external_access_token_key, or client_id and client_secret pair."

      true ->
        set_defaults(config)
    end
  end

  defp set_defaults(config) do
    scopes =
      case config.scopes do
        nil -> @bigquery_scopes
        [] -> @bigquery_scopes
        other -> other
      end

    %{config | scopes: scopes, _token_cache_key: @bigquery_token_cache_key}
  end
end
