defmodule ADK.Auth.Config do
  @moduledoc """
  Declares authentication requirements for a tool.

  Mirrors Python ADK's `AuthConfig` on tools — specifies what type of
  credential a tool needs and how to obtain it.

  ## Credential Key

  Each config carries a `credential_key` used to save/load credentials
  from a credential service. You can set it explicitly, or let it be
  auto-generated from the config fields via `credential_key/1`.

  ## Examples

      config = ADK.Auth.Config.new(
        credential_type: :oauth2,
        required: true,
        scopes: ["read", "write"],
        provider: "github"
      )

      # Auto-generated key
      ADK.Auth.Config.credential_key(config)
      #=> "adk_oauth2_a1b2c3d4..."

      # Explicit key
      config = ADK.Auth.Config.new(
        credential_type: :oauth2,
        credential_key: "my_custom_key"
      )
      ADK.Auth.Config.credential_key(config)
      #=> "my_custom_key"
  """

  @type t :: %__MODULE__{
          credential_type: ADK.Auth.Credential.credential_type(),
          required: boolean(),
          scopes: [String.t()],
          provider: String.t() | nil,
          credential_name: String.t() | nil,
          credential_key: String.t() | nil,
          raw_credential: ADK.Auth.Credential.t() | nil,
          exchanged_credential: ADK.Auth.Credential.t() | nil
        }

  defstruct [
    :credential_type,
    :provider,
    :credential_name,
    :credential_key,
    :raw_credential,
    :exchanged_credential,
    required: true,
    scopes: []
  ]

  @doc "Create a new auth config."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc """
  Returns the credential key for this config.

  If an explicit `credential_key` was set, returns it as-is.
  Otherwise, auto-generates a stable key from the config's
  `credential_type`, `raw_credential`, `provider`, and `scopes`.

  The generated key is deterministic — same inputs always produce
  the same key, regardless of map ordering.
  """
  @spec credential_key(t()) :: String.t()
  def credential_key(%__MODULE__{credential_key: key}) when is_binary(key) and key != "" do
    key
  end

  def credential_key(%__MODULE__{raw_credential: nil} = config) do
    "adk_#{config.credential_type}"
  end

  def credential_key(%__MODULE__{raw_credential: cred} = config) do
    "adk_#{config.credential_type}_#{stable_credential_digest(cred)}"
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec stable_credential_digest(ADK.Auth.Credential.t()) :: String.t()
  defp stable_credential_digest(%ADK.Auth.Credential{} = cred) do
    # Build a canonical map of stable fields (exclude transient auth state).
    # This mirrors Python's _stable_model_digest which strips model_extra
    # and transient OAuth2 fields before hashing.
    stable_fields =
      %{}
      |> put_if(:type, cred.type)
      |> put_if(:client_id, cred.client_id)
      |> put_if(:client_secret, cred.client_secret)
      |> put_if(:token_endpoint, cred.token_endpoint)
      |> put_if(:scopes, non_empty_list(cred.scopes))
      |> put_if(:api_key, cred.api_key)
      |> put_if(:service_account_key, cred.service_account_key)

    # Canonical JSON: sorted keys, compact separators
    canonical =
      stable_fields
      |> Enum.sort_by(fn {k, _} -> Atom.to_string(k) end)
      |> Enum.map(fn {k, v} -> [?", Atom.to_string(k), ?", ?:, Jason.encode!(v)] end)
      |> then(fn parts -> [?{, Enum.intersperse(parts, ?,), ?}] end)
      |> IO.iodata_to_binary()

    :crypto.hash(:sha256, canonical)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp non_empty_list([]), do: nil
  defp non_empty_list(list), do: list
end
