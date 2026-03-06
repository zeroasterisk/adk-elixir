defmodule ADK.Agent.ParallelAgentTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.ParallelAgent

  defmodule SlowAgent do
    @behaviour ADK.Agent

    def new(name, delay_ms \\ 10) do
      %{
        name: name,
        description: "Slow agent",
        module: __MODULE__,
        config: %{delay: delay_ms},
        sub_agents: []
      }
    end

    @impl true
    def run(ctx) do
      Process.sleep(ctx.agent.config.delay)
      [ADK.Event.new(%{author: ctx.agent.name, content: "done"})]
    end
  end

  defp make_ctx(agent) do
    %ADK.Context{invocation_id: "test", agent: agent}
  end

  test "runs sub-agents concurrently and collects events" do
    agents = for i <- 1..3, do: SlowAgent.new("agent_#{i}", 10)
    agent = ParallelAgent.new(name: "fan_out", sub_agents: agents)

    {time_us, events} = :timer.tc(fn -> ParallelAgent.run(make_ctx(agent)) end)

    assert length(events) == 3
    authors = Enum.map(events, & &1.author)
    assert "agent_1" in authors
    assert "agent_2" in authors
    assert "agent_3" in authors

    # Concurrent: should be ~10ms not ~30ms. Allow generous CI margin.
    assert time_us < 200_000
  end

  test "preserves order of sub-agents" do
    agents = for i <- 1..5, do: SlowAgent.new("agent_#{i}", 1)
    agent = ParallelAgent.new(name: "ordered", sub_agents: agents)

    events = ParallelAgent.run(make_ctx(agent))
    authors = Enum.map(events, & &1.author)
    assert authors == ["agent_1", "agent_2", "agent_3", "agent_4", "agent_5"]
  end

  test "returns empty list with no sub-agents" do
    agent = ParallelAgent.new(name: "empty", sub_agents: [])
    assert ParallelAgent.run(make_ctx(agent)) == []
  end
end
