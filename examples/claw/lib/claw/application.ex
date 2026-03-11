defmodule Claw.Application do
  @moduledoc """
  Claw OTP Application.

  The ADK supervision tree (started by the `:adk` application) already provides:
  - `ADK.Artifact.InMemory` — artifact storage
  - `ADK.Memory.InMemory` — cross-session memory store
  - `ADK.Session.Store.InMemory` — session persistence

  Claw only needs to start:
  - Phoenix.PubSub (for LiveView)
  - Claw.Endpoint (HTTP server)

  The ADK services are referenced by their module names in `Claw.Agents.runner/0`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # PubSub for LiveView broadcasts
      {Phoenix.PubSub, name: Claw.PubSub},

      # Phoenix endpoint (HTTP + WebSocket)
      Claw.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Claw.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Claw.Endpoint.config_change(changed, removed)
    :ok
  end
end
