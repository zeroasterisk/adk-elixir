defmodule ADK.Auth.CredentialStore do
  @moduledoc """
  Behaviour for pluggable credential storage backends.

  Mirrors Python ADK's `BaseCredentialService`. Implementations store and
  retrieve credentials keyed by a credential name (typically the tool or
  service name).

  ## Implementing a Custom Store

      defmodule MyApp.VaultStore do
        @behaviour ADK.Auth.CredentialStore

        @impl true
        def get(name, _opts), do: Vault.read(name)

        @impl true
        def put(name, credential, _opts), do: Vault.write(name, credential)

        @impl true
        def delete(name, _opts), do: Vault.delete(name)
      end
  """

  @type name :: String.t()

  @doc "Retrieve a credential by name."
  @callback get(name(), keyword()) ::
              {:ok, ADK.Auth.Credential.t()} | :not_found | {:error, term()}

  @doc "Store a credential under a name."
  @callback put(name(), ADK.Auth.Credential.t(), keyword()) :: :ok | {:error, term()}

  @doc "Delete a credential by name."
  @callback delete(name(), keyword()) :: :ok | {:error, term()}
end
