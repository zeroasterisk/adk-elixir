defmodule ADK.A2A.ServerETSTest do
  use ExUnit.Case, async: false

  test "init/1 reuses existing ETS table instead of creating new one" do
    # Clean up any existing table
    try do
      :ets.delete(:a2a_tasks)
    rescue
      ArgumentError -> :ok
    end

    agent = ADK.Agent.LlmAgent.new(name: "test", model: "test", instruction: "test")
    runner = %ADK.Runner{app_name: "test", agent: agent}

    opts = [agent: agent, runner: runner]

    # First init creates the table
    config1 = ADK.A2A.Server.init(opts)
    assert config1.table == :a2a_tasks

    # Insert something
    :ets.insert(:a2a_tasks, {"test-key", %{status: "ok"}})

    # Second init should reuse the same table
    config2 = ADK.A2A.Server.init(opts)
    assert config2.table == :a2a_tasks

    # Data should still be there
    assert [{_, %{status: "ok"}}] = :ets.lookup(:a2a_tasks, "test-key")

    # Clean up
    :ets.delete(:a2a_tasks)
  end
end
