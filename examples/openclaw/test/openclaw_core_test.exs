defmodule Openclaw.CoreTest do
  use ExUnit.Case
  
  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Openclaw.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Openclaw.Repo, {:shared, self()})
    :ok
  end

  test "core exposes an agent with the correct model" do
    {:ok, state} = Openclaw.Core.init([])
    agent = state.agent
    assert agent.name == "OpenclawAgent"
    assert agent.model == "gemini-flash-latest"
  end
end
