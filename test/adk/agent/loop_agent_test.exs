defmodule ADK.Agent.LoopAgentTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.LoopAgent

  defmodule CounterAgent do
    @behaviour ADK.Agent

    def new(opts \\ []) do
      %ADK.Agent{
        name: opts[:name] || "counter",
        description: "Increments counter",
        module: __MODULE__,
        config: %{},
        sub_agents: []
      }
    end

    @impl true
    def run(_ctx) do
      [ADK.Event.new(%{author: "counter", content: "tick"})]
    end
  end

  defmodule EscalatingAgent do
    @behaviour ADK.Agent

    def new(opts \\ []) do
      %ADK.Agent{
        name: opts[:name] || "escalator",
        description: "Escalates",
        module: __MODULE__,
        config: %{},
        sub_agents: []
      }
    end

    @impl true
    def run(_ctx) do
      [%{ADK.Event.new(%{author: "escalator", content: "done"}) | actions: %{escalate: true}}]
    end
  end

  defp make_ctx(agent) do
    %ADK.Context{invocation_id: "test", agent: agent}
  end

  test "runs sub-agents up to max_iterations" do
    counter = CounterAgent.new()
    agent = LoopAgent.new(name: "test_loop", sub_agents: [counter], max_iterations: 3)
    events = LoopAgent.run(make_ctx(agent))

    assert length(events) == 3
    assert Enum.all?(events, &(&1.author == "counter"))
  end

  test "stops early on escalation" do
    counter = CounterAgent.new()
    escalator = EscalatingAgent.new()
    agent = LoopAgent.new(name: "test_loop", sub_agents: [counter, escalator], max_iterations: 10)
    events = LoopAgent.run(make_ctx(agent))

    # First iteration: counter (1) + escalator (1) = 2, then loop stops
    assert length(events) == 2
    assert List.last(events).actions.escalate == true
  end

  test "returns empty list with no sub-agents" do
    agent = LoopAgent.new(name: "empty", sub_agents: [], max_iterations: 5)
    assert LoopAgent.run(make_ctx(agent)) == []
  end

  test "default max_iterations is 10" do
    agent = LoopAgent.new(name: "default", sub_agents: [])
    assert agent.config.max_iterations == 10
  end
end
