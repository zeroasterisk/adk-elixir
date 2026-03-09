defmodule Claw.A2AController do
  @moduledoc "Thin controller wrapping ADK.A2A.Server for the A2A protocol."
  use Phoenix.Controller, formats: [:json]

  def agent_card(conn, _params) do
    # Delegate to the A2A server plug
    config = a2a_config()
    ADK.A2A.Server.call(%{conn | path_info: [".well-known", "agent.json"]}, config)
  end

  def rpc(conn, _params) do
    config = a2a_config()
    ADK.A2A.Server.call(%{conn | path_info: []}, config)
  end

  defp a2a_config do
    agent = Claw.Agents.router()

    ADK.A2A.Server.init(
      agent: agent,
      runner: %ADK.Runner{app_name: "claw", agent: agent},
      url: "http://localhost:4000/a2a"
    )
  end
end
