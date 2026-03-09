defmodule ADK.A2A.ServerETSTest do
  use ExUnit.Case, async: false

  test "init/1 creates ETS-backed config with adk_config_table" do
    agent = ADK.Agent.LlmAgent.new(name: "test", model: "test", instruction: "test")
    runner = %ADK.Runner{app_name: "test", agent: agent}

    opts = [agent: agent, runner: runner]

    config = ADK.A2A.Server.init(opts)

    # The underlying A2A.Server creates an ETS table (anonymous ref)
    assert is_reference(config.table)

    # ADK stores its own config table reference
    assert is_reference(config.adk_config_table)

    # ADK config should be retrievable
    [{:config, adk_config}] = :ets.lookup(config.adk_config_table, :config)
    assert adk_config.agent == agent
    assert adk_config.runner == runner
  end
end
