defmodule Openclaw.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Openclaw.Repo,
      Openclaw.Core
    ]

    opts = [strategy: :one_for_one, name: Openclaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
