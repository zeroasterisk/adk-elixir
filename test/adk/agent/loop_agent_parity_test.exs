# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Agent.LoopAgentParityTest do
  @moduledoc """
  Parity tests ported from Python's test_loop_agent.py.

  Focuses on behavioral equivalents of the Python suite:
  - test_run_async (basic loop with max_iterations)
  - test_run_async_skip_if_no_sub_agent (no sub-agents → empty)
  - test_run_async_with_escalate_action (escalation stops loop, remaining agents skipped,
    but escalating agent's subsequent events are included)

  Python-only features (resumability/LoopAgentState mid-run resume) are not ported
  as the Elixir runtime does not have session-based resumability.
  """

  use ExUnit.Case, async: true

  alias ADK.Agent.LoopAgent

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_ctx(agent) do
    %ADK.Context{invocation_id: "parity_test", agent: agent}
  end

  # A simple agent that emits one text event per run.
  defp simple_agent(name) do
    ADK.Agent.Custom.new(
      name: name,
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(%{author: name, content: "Hello, async #{name}!"})]
      end
    )
  end

  # An agent that emits an escalate event then a follow-up event.
  # Mirrors Python's _TestingAgentWithEscalateAction.
  defp escalating_agent_multi_event(name) do
    ADK.Agent.Custom.new(
      name: name,
      run_fn: fn _agent, _ctx ->
        [
          %{
            ADK.Event.new(%{author: name, content: "Hello, async #{name}!"})
            | actions: %{escalate: true}
          },
          ADK.Event.new(%{author: name, content: "I have done my job after escalation!!"})
        ]
      end
    )
  end

  # ---------------------------------------------------------------------------
  # test_run_async equivalent
  # Sub-agents run once per iteration; loop repeats max_iterations times.
  # ---------------------------------------------------------------------------

  test "loop runs sub-agent exactly max_iterations times" do
    agent_name = "parity_simple_agent"
    sub = simple_agent(agent_name)
    loop = LoopAgent.new(name: "parity_loop", sub_agents: [sub], max_iterations: 2)

    events = ADK.Agent.run(loop, make_ctx(loop))

    # Two iterations, one event each → 2 events total
    assert length(events) == 2
    assert Enum.all?(events, fn e -> e.author == agent_name end)
    assert Enum.all?(events, fn e -> e.content == "Hello, async #{agent_name}!" end)
  end

  test "loop with multiple sub-agents runs all agents each iteration" do
    a = simple_agent("parity_agent_1")
    b = simple_agent("parity_agent_2")
    loop = LoopAgent.new(name: "parity_multi_loop", sub_agents: [a, b], max_iterations: 2)

    events = ADK.Agent.run(loop, make_ctx(loop))

    # 2 iterations × 2 agents = 4 events
    assert length(events) == 4

    authors = Enum.map(events, & &1.author)
    assert authors == ["parity_agent_1", "parity_agent_2", "parity_agent_1", "parity_agent_2"]
  end

  # ---------------------------------------------------------------------------
  # test_run_async_skip_if_no_sub_agent equivalent
  # ---------------------------------------------------------------------------

  test "loop with no sub-agents produces no events" do
    loop = LoopAgent.new(name: "parity_empty_loop", sub_agents: [], max_iterations: 2)
    events = ADK.Agent.run(loop, make_ctx(loop))
    assert events == []
  end

  # ---------------------------------------------------------------------------
  # test_run_async_with_escalate_action equivalent
  #
  # Python test: 3 sub-agents [non_escalating, escalating, ignored]
  # Escalation stops the loop; agent after escalating one is not run.
  # Escalating agent may continue emitting events after escalation signal.
  # ---------------------------------------------------------------------------

  test "escalating agent stops loop and subsequent agents are skipped" do
    non_escalating = simple_agent("parity_non_escalating")
    escalating = escalating_agent_multi_event("parity_escalating")
    ignored = simple_agent("parity_ignored")

    loop =
      LoopAgent.new(
        name: "parity_escalate_loop",
        sub_agents: [non_escalating, escalating, ignored]
      )

    events = ADK.Agent.run(loop, make_ctx(loop))

    authors = Enum.map(events, & &1.author)

    # non_escalating runs, escalating runs (emits 2 events), ignored is skipped
    assert "parity_non_escalating" in authors
    assert Enum.count(authors, &(&1 == "parity_escalating")) >= 1
    refute "parity_ignored" in authors
  end

  test "escalating agent's post-escalation events are included in output" do
    # Python's _TestingAgentWithEscalateAction yields a second event after escalation.
    # Both events should appear in the final output.
    escalating = escalating_agent_multi_event("parity_esc_multi")

    loop =
      LoopAgent.new(
        name: "parity_multi_event_loop",
        sub_agents: [escalating]
      )

    events = ADK.Agent.run(loop, make_ctx(loop))

    assert length(events) == 2
    assert Enum.at(events, 0).content == "Hello, async parity_esc_multi!"
    assert Enum.at(events, 1).content == "I have done my job after escalation!!"
    assert Enum.at(events, 0).actions.escalate == true
  end

  test "loop does not continue after escalation even if max_iterations not reached" do
    escalating = escalating_agent_multi_event("parity_esc_stop")

    # max_iterations = 10 but escalation should stop after first iteration
    loop =
      LoopAgent.new(
        name: "parity_early_stop_loop",
        sub_agents: [escalating],
        max_iterations: 10
      )

    events = ADK.Agent.run(loop, make_ctx(loop))

    # Only one iteration ran: escalating agent emits 2 events, loop stops
    assert length(events) == 2
  end

  test "non-escalating agents before escalating agent are included" do
    non_escalating = simple_agent("parity_before_esc")
    escalating = escalating_agent_multi_event("parity_esc_in_middle")

    loop =
      LoopAgent.new(
        name: "parity_before_esc_loop",
        sub_agents: [non_escalating, escalating]
      )

    events = ADK.Agent.run(loop, make_ctx(loop))

    # non_escalating (1 event) + escalating (2 events) = 3
    assert length(events) == 3
    assert Enum.at(events, 0).author == "parity_before_esc"
    assert Enum.at(events, 1).author == "parity_esc_in_middle"
    assert Enum.at(events, 2).author == "parity_esc_in_middle"
  end
end
