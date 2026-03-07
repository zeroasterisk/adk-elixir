defmodule ADK.Session.Store do
  @moduledoc """
  Behaviour for session persistence stores.

  Implement this behaviour to add a custom persistence backend.
  """

  @callback load(app_name :: String.t(), user_id :: String.t(), session_id :: String.t()) ::
              {:ok, map()} | {:error, :not_found}

  @callback save(session :: ADK.Session.t()) :: :ok | {:error, term()}

  @callback delete(app_name :: String.t(), user_id :: String.t(), session_id :: String.t()) :: :ok

  @callback list(app_name :: String.t(), user_id :: String.t()) :: [String.t()]
end
