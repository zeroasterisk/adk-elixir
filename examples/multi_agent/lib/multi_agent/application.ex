defmodule MultiAgent.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # ADK.Application already starts SessionRegistry and SessionSupervisor
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: MultiAgent.Supervisor)
  end
end
