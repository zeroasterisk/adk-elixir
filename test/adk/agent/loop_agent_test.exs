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

  # -- Basic loop tests --

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
    # With no sub-agents, each iteration produces 0 events, runs max_iterations times
    assert ADK.Agent.run(agent, make_ctx(agent)) == []
  end

  test "default max_iterations is 10" do
    agent = LoopAgent.new(name: "default", sub_agents: [])
    assert agent.max_iterations == 10
  end

  test "multiple sub-agents run in sequence each iteration" do
    a = counter_agent(name: "a")
    b = counter_agent(name: "b")
    agent = LoopAgent.new(name: "multi", sub_agents: [a, b], max_iterations: 2)
    events = ADK.Agent.run(agent, make_ctx(agent))

    # 2 iterations * 2 agents = 4 events
    assert length(events) == 4
  end

  # -- Exit condition tests --

  test "exit_condition stops loop when it returns true" do
    call_count = :counters.new(1, [:atomics])

    counting_agent = ADK.Agent.Custom.new(
      name: "counting",
      run_fn: fn _agent, ctx ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)
        ctx = ADK.Context.put_temp(ctx, :iteration, count)
        # We need to propagate the temp_state somehow
        # The child_ctx is what LoopAgent merges back
        [ADK.Event.new(%{author: "counting", content: "iter=#{count}"})]
      end
    )

    agent = LoopAgent.new(
      name: "cond_loop",
      sub_agents: [counting_agent],
      max_iterations: 100,
      exit_condition: fn _ctx ->
        :counters.get(call_count, 1) >= 3
      end
    )

    events = ADK.Agent.run(agent, make_ctx(agent))
    assert length(events) == 3
  end

  test "exit_condition nil means loop runs to max_iterations" do
    agent = LoopAgent.new(
      name: "no_cond",
      sub_agents: [counter_agent()],
      max_iterations: 4,
      exit_condition: nil
    )

    events = ADK.Agent.run(agent, make_ctx(agent))
    assert length(events) == 4
  end

  test "exit_condition that always returns true stops after first iteration" do
    agent = LoopAgent.new(
      name: "instant_exit",
      sub_agents: [counter_agent()],
      max_iterations: 100,
      exit_condition: fn _ctx -> true end
    )

    events = ADK.Agent.run(agent, make_ctx(agent))
    assert length(events) == 1
  end

  test "exit_condition receives context with temp_state" do
    # Agent that sets temp_state
    setter = ADK.Agent.Custom.new(
      name: "setter",
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(%{author: "setter", content: "set"})]
      end
    )

    agent = LoopAgent.new(
      name: "ctx_check",
      sub_agents: [setter],
      max_iterations: 10,
      exit_condition: fn ctx ->
        # Context is passed, verify it's a Context struct
        is_map(ctx.temp_state)
      end
    )

    # Should exit after 1 iteration since condition checks ctx is valid
    events = ADK.Agent.run(agent, make_ctx(agent))
    assert length(events) == 1
  end

  # -- Escalation + exit_condition interaction --

  test "escalation takes priority over exit_condition" do
    escalator = escalating_agent()
    agent = LoopAgent.new(
      name: "esc_vs_cond",
      sub_agents: [escalator],
      max_iterations: 100,
      exit_condition: fn _ctx -> false end  # never exit via condition
    )

    events = ADK.Agent.run(agent, make_ctx(agent))
    assert length(events) == 1
    assert List.last(events).actions.escalate == true
  end

  # -- Nested loops --

  test "nested loop agents work correctly" do
    inner_counter = counter_agent(name: "inner")
    inner_loop = LoopAgent.new(
      name: "inner_loop",
      sub_agents: [inner_counter],
      max_iterations: 2
    )

    outer_loop = LoopAgent.new(
      name: "outer_loop",
      sub_agents: [inner_loop],
      max_iterations: 3
    )

    events = ADK.Agent.run(outer_loop, make_ctx(outer_loop))
    # 3 outer iterations * 2 inner iterations = 6 events
    assert length(events) == 6
    assert Enum.all?(events, &(&1.author == "counter"))
  end

  test "nested loop with inner escalation propagates to outer" do
    counter = counter_agent(name: "tick")
    escalator = escalating_agent(name: "esc")

    inner_loop = LoopAgent.new(
      name: "inner",
      sub_agents: [counter, escalator],
      max_iterations: 10
    )

    outer_loop = LoopAgent.new(
      name: "outer",
      sub_agents: [inner_loop],
      max_iterations: 3
    )

    events = ADK.Agent.run(outer_loop, make_ctx(outer_loop))
    # Inner loop: counter + escalator = 2 events, then escalation propagates to outer
    # Outer loop also sees escalation and stops after 1 iteration
    assert length(events) == 2
    assert Enum.any?(events, fn e -> e.actions == %{escalate: true} end)
  end

  # -- Build/new --

  test "build/1 returns ok tuple" do
    assert {:ok, %LoopAgent{name: "test"}} = LoopAgent.build(name: "test")
  end

  test "build/1 returns error on missing required fields" do
    assert {:error, _} = LoopAgent.build([])
  end

  test "new/1 with exit_condition" do
    cond_fn = fn _ctx -> true end
    agent = LoopAgent.new(name: "cond", exit_condition: cond_fn)
    assert agent.exit_condition == cond_fn
  end
end
