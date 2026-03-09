defmodule ADK.Auth.Config do
  @moduledoc """
  Declares authentication requirements for a tool.

  Mirrors Python ADK's `AuthConfig` on tools — specifies what type of
  credential a tool needs and how to obtain it.

  ## Examples

      config = ADK.Auth.Config.new(
        credential_type: :oauth2,
        required: true,
        scopes: ["read", "write"],
        provider: "github"
      )
  """

  @type t :: %__MODULE__{
          credential_type: ADK.Auth.Credential.credential_type(),
          required: boolean(),
          scopes: [String.t()],
          provider: String.t() | nil,
          credential_name: String.t() | nil
        }

  defstruct [
    :credential_type,
    :provider,
    :credential_name,
    required: true,
    scopes: []
  ]

  @doc "Create a new auth config."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)
end
