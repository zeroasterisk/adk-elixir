defmodule CustomAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Session store
      {ADK.Session.Store.InMemory, name: CustomAgent.SessionStore}
    ]

    opts = [strategy: :one_for_one, name: CustomAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
