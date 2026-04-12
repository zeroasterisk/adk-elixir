defmodule ADK.ParityFeaturesTest do
  use ExUnit.Case
  use ADK.LLM.TestHelper

  alias ADK.Tool
  alias ADK.Agent.LlmAgent
  alias ADK.Plugin
  alias ADK.Runner

  defmodule DummyMath do
    def sqrt(x), do: x
  end

  test "Tool.wrap/1 wraps captured function" do
    func = &DummyMath.sqrt/1
    tool = Tool.wrap(func)
    assert tool.name == "sqrt"
    assert tool.description == "Auto-wrapped function"
    assert tool.func == func
  end

  test "Tool.wrap/1 wraps MFA tuple" do
    mfa = {DummyMath, :sqrt, []}
    tool = Tool.wrap(mfa)
    assert tool.name == "sqrt"
    assert tool.description == "Auto-wrapped function"
    assert tool.func == mfa
  end

  # Mock plugin for testing hooks
  defmodule MockAgentPlugin do
    @behaviour Plugin

    def init(opts), do: {:ok, opts}

    def before_agent(ctx, agent) do
      send(self(), {:before_agent_called, agent.name})
      {:cont, ctx}
    end

    def after_agent(_ctx, agent, result) do
      send(self(), {:after_agent_called, agent.name})
      result
    end
  end

  test "before_agent and after_agent plugin hooks are called" do
    agent = LlmAgent.new(name: "test_agent", model: "test", instruction: "test")
    ctx = %ADK.Context{agent: agent}
    plugins = [{MockAgentPlugin, []}]

    assert {:cont, _ctx} = Plugin.run_before_agent(plugins, ctx, agent)
    assert_received {:before_agent_called, "test_agent"}

    result = []
    assert ^result = Plugin.run_after_agent(plugins, ctx, agent, result)
    assert_received {:after_agent_called, "test_agent"}
  end

  # Mock callback for testing per-agent callbacks
  defmodule MockCallback do
    @behaviour ADK.Callback

    def before_model(cb_ctx) do
      send(self(), {:callback_before_model, cb_ctx.agent.name})
      {:cont, cb_ctx}
    end
  end

  test "per-agent callbacks are merged and executed" do
    setup_mock_llm([
      mock_response("Hello!")
    ])

    agent = LlmAgent.new(
      name: "test_agent",
      model: "mock_model",
      instruction: "test",
      callbacks: [MockCallback]
    )
    
    runner = Runner.new(app_name: "test_app", agent: agent)
    
    Runner.run(runner, "user1", "sess1", "hi")
    
    assert_received {:callback_before_model, "test_agent"}
  end
end
