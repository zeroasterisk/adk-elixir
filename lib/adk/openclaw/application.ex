defmodule ADK.OpenClaw.Application do
  use Application

  def start(_type, _args) do
    {:ok, _} = ADK.Application.start(:normal, [])
    
    children = [
      {ADK.Memory.InMemory, name: ADK.Memory.InMemory},
      {ADK.OpenClaw.Core, []}
    ]

    opts = [strategy: :one_for_one, name: ADK.OpenClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
