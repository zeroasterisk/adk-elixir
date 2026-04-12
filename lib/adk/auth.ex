defmodule ADK.Auth do
  @moduledoc """
  Authentication subsystem for the Agent Development Kit (ADK).

  This module serves as the primary namespace and facade for authentication-related
  functionality, including credentials, configuration, stores, OAuth2 flows, and
  pluggable authentication providers.

  ## Pluggable Auth Providers
  ADK v1.27 introduced `AuthProviderRegistry` to manage multiple auth providers dynamically.
  You can define a custom provider by implementing the `ADK.Auth.Provider` behavior
  and registering it via `ADK.Auth.ProviderRegistry.register/2`.

      # Define a provider
      defmodule MyApp.GithubProvider do
        @behaviour ADK.Auth.Provider

        @impl true
        def get_auth_credential(config, _context) do
          {:ok, ADK.Auth.Credential.api_key(ADK.Config.github_token())}
        end
      end

      # Register it
      ADK.Auth.ProviderRegistry.register(:oauth2, MyApp.GithubProvider)

  ## Modules
  - `ADK.Auth.Credential`: Represents an authentication credential.
  - `ADK.Auth.Config`: Declares authentication requirements for a tool.
  - `ADK.Auth.CredentialManager`: Orchestrates the OAuth2 lifecycle (exchange/refresh/save).
  - `ADK.Auth.CredentialStore`: Behavior for persisting credentials.
  - `ADK.Auth.InMemoryStore`: Simple in-memory credential store.
  - `ADK.Auth.OAuth2`: Core stateless OAuth2 functions.
  - `ADK.Auth.Provider`: Behavior for custom authentication providers.
  - `ADK.Auth.ProviderRegistry`: Registry for dynamic auth providers.
  """
end
