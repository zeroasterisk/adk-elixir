defmodule ADK.A2A.ServerETSTest do
  use ExUnit.Case, async: false
  @moduletag :a2a

  test "init/1 creates ETS-backed config with adk_config_table" do
    agent = ADK.Agent.LlmAgent.new(name: "test", model: "test", instruction: "test")
    runner = %ADK.Runner{app_name: "test", agent: agent}

    uid = System.unique_integer([:positive])

    opts = [
      agent: agent,
      runner: runner,
      config_table_name: :"ets_test_config_#{uid}",
      task_table_name: :"ets_test_tasks_#{uid}"
    ]

    config = ADK.A2A.Server.init(opts)

    # The underlying A2A.Server uses the task_table_name
    assert config.table == :"ets_test_tasks_#{uid}"

    # ADK stores its own named config table
    assert config.adk_config_table == :"ets_test_config_#{uid}"

    # ADK config should be retrievable
    [{:config, adk_config}] = :ets.lookup(config.adk_config_table, :config)
    assert adk_config.agent == agent
    assert adk_config.runner == runner
  end

  test "multiple init/1 calls do not crash (ETS table reuse)" do
    agent = ADK.Agent.LlmAgent.new(name: "test", model: "test", instruction: "test")
    runner = %ADK.Runner{app_name: "test", agent: agent}

    opts = [
      agent: agent,
      runner: runner,
      config_table_name: :ets_multi_config,
      task_table_name: :ets_multi_tasks
    ]

    config1 = ADK.A2A.Server.init(opts)
    config2 = ADK.A2A.Server.init(opts)

    # Both should use the same named tables
    assert config1.table == config2.table
    assert config1.adk_config_table == config2.adk_config_table
  end
end
