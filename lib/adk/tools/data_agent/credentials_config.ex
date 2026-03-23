defmodule ADK.Tool.DataAgent.CredentialsConfig do
  @moduledoc "Credentials Configuration for Data Agent tools."

  defstruct [
    :client_id,
    :client_secret,
    :token
  ]

  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
