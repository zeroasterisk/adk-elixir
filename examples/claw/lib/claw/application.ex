defmodule Claw.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # PubSub for LiveView
      {Phoenix.PubSub, name: Claw.PubSub},
      # Phoenix endpoint
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
