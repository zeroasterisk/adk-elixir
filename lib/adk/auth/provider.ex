defmodule ADK.Auth.Provider do
  @moduledoc """
  Behavior for custom authentication providers.

  Allows defining custom logic for obtaining credentials based on an `ADK.Auth.Config`.
  This is the Elixir equivalent to Python ADK's `BaseAuthProvider`.
  """

  alias ADK.Auth.{Config, Credential}
  alias ADK.ToolContext

  @doc """
  Provide an AuthCredential asynchronously (in Elixir, this means normal execution,
  potentially making network calls).

  ## Parameters
  - `auth_config`: The current authentication configuration (`ADK.Auth.Config.t()`).
  - `context`: The current tool context (`ADK.ToolContext.t()`).

  ## Returns
  - `{:ok, ADK.Auth.Credential.t()}` if successful.
  - `{:error, reason}` if unavailable or an error occurred.
  """
  @callback get_auth_credential(Config.t(), ToolContext.t()) ::
              {:ok, Credential.t()} | {:error, term()}
end
