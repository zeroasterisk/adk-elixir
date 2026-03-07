defmodule ADK.Agent.ParallelAgentTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.ParallelAgent

  defp slow_agent(name, delay_ms \\ 10) do
    ADK.Agent.Custom.new(
      name: name,
      run_fn: fn agent, _ctx ->
        Process.sleep(delay_ms)
        [ADK.Event.new(%{author: ADK.Agent.name(agent), content: "done"})]
      end
    )
  end

  defp make_ctx(agent) do
    %ADK.Context{invocation_id: "test", agent: agent}
  end

  test "runs sub-agents concurrently and collects events" do
    agents = for i <- 1..3, do: slow_agent("agent_#{i}", 10)
    agent = ParallelAgent.new(name: "fan_out", sub_agents: agents)

    {time_us, events} = :timer.tc(fn -> ADK.Agent.run(agent, make_ctx(agent)) end)

    assert length(events) == 3
    authors = Enum.map(events, & &1.author)
    assert "agent_1" in authors
    assert "agent_2" in authors
    assert "agent_3" in authors

    # Concurrent: should be ~10ms not ~30ms. Allow generous CI margin.
    assert time_us < 200_000
  end

  test "preserves order of sub-agents" do
    agents = for i <- 1..5, do: slow_agent("agent_#{i}", 1)
    agent = ParallelAgent.new(name: "ordered", sub_agents: agents)

    events = ADK.Agent.run(agent, make_ctx(agent))
    authors = Enum.map(events, & &1.author)
    assert authors == ["agent_1", "agent_2", "agent_3", "agent_4", "agent_5"]
  end

  test "returns empty list with no sub-agents" do
    agent = ParallelAgent.new(name: "empty", sub_agents: [])
    assert ADK.Agent.run(agent, make_ctx(agent)) == []
  end
end
