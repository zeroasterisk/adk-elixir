defmodule ADK.Auth.ProviderRegistry do
  @moduledoc """
  Registry for dynamic auth providers.

  Maps `credential_type` (like `:oauth2`, `:api_key`) to a module implementing
  `ADK.Auth.Provider`. This mirrors Python ADK's `AuthProviderRegistry`.

  Uses application environment (`Application.get_env/3`) to store mappings globally
  for simplicity and flexibility.
  """

  alias ADK.Auth.Credential

  @doc """
  Registers a provider module for a given credential type.
  """
  @spec register(Credential.credential_type(), module()) :: :ok
  def register(credential_type, provider_module)
      when is_atom(credential_type) and is_atom(provider_module) do
    providers = ADK.Config.auth_providers()

    Application.put_env(
      :adk,
      :auth_providers,
      Map.put(providers, credential_type, provider_module)
    )
  end

  @doc """
  Gets the registered provider module for a given credential type.

  Returns `nil` if no provider is registered.
  """
  @spec get_provider(Credential.credential_type()) :: module() | nil
  def get_provider(credential_type) when is_atom(credential_type) do
    providers = ADK.Config.auth_providers()
    Map.get(providers, credential_type)
  end

  @doc """
  Clears all registered providers. Useful for testing.
  """
  @spec clear() :: :ok
  def clear do
    Application.delete_env(:adk, :auth_providers)
  end
end
