defmodule ADK.Tool.Bigtable.CredentialsConfig do
  @moduledoc """
  Bigtable Credentials Configuration for Google API tools.

  ## Status
  ⚠️ **Stub/Experimental**: This module is part of the Bigtable tools which are not fully implemented in v0.0.1. Full support is targeted for v0.0.2.
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

  @bigtable_scopes [
    "https://www.googleapis.com/auth/bigtable.admin",
    "https://www.googleapis.com/auth/bigtable.data"
  ]
  @bigtable_token_cache_key "bigtable_token_cache"

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

    config =
      case config.credentials do
        %{client_id: id, client_secret: secret, scopes: sc} ->
          %{config | client_id: id, client_secret: secret, scopes: sc}

        _ ->
          config
      end

    cond do
      config.credentials != nil ->
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
        nil -> @bigtable_scopes
        [] -> @bigtable_scopes
        other -> other
      end

    %{config | scopes: scopes, _token_cache_key: @bigtable_token_cache_key}
  end
end
