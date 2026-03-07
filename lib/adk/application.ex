defmodule ADK.Application do
  @moduledoc """
  OTP Application for ADK.

  Starts the supervision tree with:
  - `ADK.SessionRegistry` — Registry for session lookup by `{app_name, user_id, session_id}`
  - `ADK.SessionSupervisor` — DynamicSupervisor for session processes
  - `ADK.Session.Store.InMemory` — ETS-backed in-memory session store
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: ADK.SessionRegistry},
      {DynamicSupervisor, name: ADK.SessionSupervisor, strategy: :one_for_one},
      ADK.Session.Store.InMemory
    ]

    opts = [strategy: :one_for_one, name: ADK.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
