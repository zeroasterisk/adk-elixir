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

  # ── Branch naming ──────────────────────────────────────────────────

  test "events carry branch = parent_branch.child_name" do
    agents =
      for name <- ~w(alpha beta) do
        ADK.Agent.Custom.new(
          name: name,
          run_fn: fn _agent, ctx ->
            [ADK.Event.new(%{author: name, branch: ctx.branch, content: "ok"})]
          end
        )
      end

    agent = ParallelAgent.new(name: "par", sub_agents: agents)
    events = ADK.Agent.run(agent, make_ctx(agent))

    branches = Enum.map(events, & &1.branch)
    assert "alpha" in branches
    assert "beta" in branches
    assert length(events) == 2
  end

  test "nested sequential agents propagate branches correctly" do
    # parallel -> sequential -> [child_a, child_b]
    child_a =
      ADK.Agent.Custom.new(
        name: "child_a",
        run_fn: fn _agent, ctx ->
          [ADK.Event.new(%{author: "child_a", branch: ctx.branch, content: "a"})]
        end
      )

    child_b =
      ADK.Agent.Custom.new(
        name: "child_b",
        run_fn: fn _agent, ctx ->
          [ADK.Event.new(%{author: "child_b", branch: ctx.branch, content: "b"})]
        end
      )

    seq = ADK.Agent.SequentialAgent.new(name: "seq", sub_agents: [child_a, child_b])

    lone =
      ADK.Agent.Custom.new(
        name: "lone",
        run_fn: fn _agent, ctx ->
          [ADK.Event.new(%{author: "lone", branch: ctx.branch, content: "solo"})]
        end
      )

    agent = ParallelAgent.new(name: "par", sub_agents: [seq, lone])
    events = ADK.Agent.run(agent, make_ctx(agent))

    # Sequential children should get seq.child_a and seq.child_b branches
    seq_branches =
      events
      |> Enum.filter(&(&1.author in ~w(child_a child_b)))
      |> Enum.map(& &1.branch)

    assert "seq.child_a" in seq_branches
    assert "seq.child_b" in seq_branches

    # Lone agent gets its own branch
    lone_event = Enum.find(events, &(&1.author == "lone"))
    assert lone_event.branch == "lone"

    # Different sub-agents get different branch prefixes
    refute Enum.any?(seq_branches, &(&1 == "lone"))
  end

  # ── Error propagation ─────────────────────────────────────────────

  test "exception in one sub-agent propagates to caller" do
    good =
      ADK.Agent.Custom.new(
        name: "good",
        run_fn: fn _agent, _ctx ->
          Process.sleep(50)
          [ADK.Event.new(%{author: "good", content: "ok"})]
        end
      )

    bad =
      ADK.Agent.Custom.new(
        name: "bad",
        run_fn: fn _agent, _ctx ->
          raise "boom"
        end
      )

    agent = ParallelAgent.new(name: "par", sub_agents: [bad, good])

    # Task.async_stream links tasks; run in a spawned process to observe the crash
    test_pid = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            ADK.Agent.run(agent, make_ctx(agent))
            :ok
          catch
            :exit, _ -> :crashed
          end

        send(test_pid, {:result, result})
      end)

    receive do
      {:result, :crashed} -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} when reason != :normal -> :ok
    after
      5_000 -> flunk("expected sub-agent exception to propagate")
    end
  end

  # ── Event interleaving ────────────────────────────────────────────

  test "multi-event agents produce events in sub-agent order" do
    # Each agent produces 3 events
    make_multi = fn name ->
      ADK.Agent.Custom.new(
        name: name,
        run_fn: fn _agent, ctx ->
          for i <- 1..3 do
            ADK.Event.new(%{author: name, branch: ctx.branch, content: "#{name}-#{i}"})
          end
        end
      )
    end

    agents = [make_multi.("a"), make_multi.("b")]
    agent = ParallelAgent.new(name: "par", sub_agents: agents)
    events = ADK.Agent.run(agent, make_ctx(agent))

    # All 6 events collected
    assert length(events) == 6

    # Events from agent "a" come before events from agent "b" (ordered: true)
    a_events = Enum.filter(events, &(&1.author == "a"))
    b_events = Enum.filter(events, &(&1.author == "b"))
    assert length(a_events) == 3
    assert length(b_events) == 3

    # Within each agent, order is preserved
    a_contents = Enum.map(a_events, & &1.content)
    assert a_contents == ["a-1", "a-2", "a-3"]

    b_contents = Enum.map(b_events, & &1.content)
    assert b_contents == ["b-1", "b-2", "b-3"]
  end

  # ── Nested agents ─────────────────────────────────────────────────

  test "parallel containing sequential: events in correct order with branches" do
    step1 =
      ADK.Agent.Custom.new(
        name: "step1",
        run_fn: fn _agent, ctx ->
          [ADK.Event.new(%{author: "step1", branch: ctx.branch, content: "first"})]
        end
      )

    step2 =
      ADK.Agent.Custom.new(
        name: "step2",
        run_fn: fn _agent, ctx ->
          [ADK.Event.new(%{author: "step2", branch: ctx.branch, content: "second"})]
        end
      )

    seq = ADK.Agent.SequentialAgent.new(name: "pipeline", sub_agents: [step1, step2])

    solo =
      ADK.Agent.Custom.new(
        name: "solo",
        run_fn: fn _agent, ctx ->
          [ADK.Event.new(%{author: "solo", branch: ctx.branch, content: "alone"})]
        end
      )

    agent = ParallelAgent.new(name: "par", sub_agents: [seq, solo])
    events = ADK.Agent.run(agent, make_ctx(agent))

    # 3 events total: step1, step2, solo
    assert length(events) == 3

    # Sequential sub-agent events maintain internal order
    seq_events = Enum.filter(events, &(&1.author in ~w(step1 step2)))
    seq_authors = Enum.map(seq_events, & &1.author)
    assert seq_authors == ["step1", "step2"]

    # Sequential events get nested branches
    assert Enum.all?(seq_events, &String.starts_with?(&1.branch, "pipeline."))

    # Solo event has its own branch
    solo_event = Enum.find(events, &(&1.author == "solo"))
    assert solo_event.branch == "solo"
  end
end
