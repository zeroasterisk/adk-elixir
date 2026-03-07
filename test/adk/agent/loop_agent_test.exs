defmodule ADK.Agent.LoopAgentTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.LoopAgent

  defp counter_agent(opts \\ []) do
    ADK.Agent.Custom.new(
      name: opts[:name] || "counter",
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(%{author: "counter", content: "tick"})]
      end
    )
  end

  defp escalating_agent(opts \\ []) do
    ADK.Agent.Custom.new(
      name: opts[:name] || "escalator",
      run_fn: fn _agent, _ctx ->
        [%{ADK.Event.new(%{author: "escalator", content: "done"}) | actions: %{escalate: true}}]
      end
    )
  end

  defp make_ctx(agent) do
    %ADK.Context{invocation_id: "test", agent: agent}
  end

  test "runs sub-agents up to max_iterations" do
    counter = counter_agent()
    agent = LoopAgent.new(name: "test_loop", sub_agents: [counter], max_iterations: 3)
    events = ADK.Agent.run(agent, make_ctx(agent))

    assert length(events) == 3
    assert Enum.all?(events, &(&1.author == "counter"))
  end

  test "stops early on escalation" do
    counter = counter_agent()
    escalator = escalating_agent()
    agent = LoopAgent.new(name: "test_loop", sub_agents: [counter, escalator], max_iterations: 10)
    events = ADK.Agent.run(agent, make_ctx(agent))

    # First iteration: counter (1) + escalator (1) = 2, then loop stops
    assert length(events) == 2
    assert List.last(events).actions.escalate == true
  end

  test "returns empty list with no sub-agents" do
    agent = LoopAgent.new(name: "empty", sub_agents: [], max_iterations: 5)
    assert ADK.Agent.run(agent, make_ctx(agent)) == []
  end

  test "default max_iterations is 10" do
    agent = LoopAgent.new(name: "default", sub_agents: [])
    assert agent.max_iterations == 10
  end
end
