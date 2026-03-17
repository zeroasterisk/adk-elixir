defmodule Adk.Agent.SequentialAgentTest do
  use ExUnit.Case, async: true

  alias Adk.Agent.BaseAgent
  alias Adk.Agent.InvocationContext
  alias Adk.Agent.SequentialAgent
  alias Adk.Agent.SequentialAgentState
  alias Adk.App.ResumabilityConfig
  alias Adk.Event.Event
  alias Adk.Session.InMemorySessionService

  defmodule TestingAgent do
    @moduledoc false

    use Adk.Agent.BaseAgent

    @impl true
    def run_async_impl(agent, _ctx) do
      Stream.unfold(1, fn
        1 ->
          event = %Event{
            author: agent.name,
            content: %{parts: [%{text: "Hello, async #{agent.name}!"}]}
          }
          {event, nil}
        _ -> nil
      end)
    end

    @impl true
    def run_live_impl(agent, _ctx) do
      Stream.unfold(1, fn
        1 ->
          event = %Event{
            author: agent.name,
            content: %{parts: [%{text: "Hello, live #{agent.name}!"}]}
          }
          {event, nil}
        _ -> nil
      end)
    end
  end

  defp create_parent_invocation_context(test_name, agent, resumable \\ false) do
    {:ok, session} = InMemorySessionService.create_session("test_app", "test_user")
    %InvocationContext{
      invocation_id: "#{test_name}_invocation_id",
      agent: agent,
      session: session,
      session_service: InMemorySessionService,
      resumability_config: %ResumabilityConfig{is_resumable: resumable}
    }
  end

  test "run_async" do
    agent_1 = %TestingAgent{name: "test_run_async_test_agent_1"}
    agent_2 = %TestingAgent{name: "test_run_async_test_agent_2"}
    sequential_agent = %SequentialAgent{
      name: "test_run_async_test_agent",
      sub_agents: [agent_1, agent_2]
    }
    parent_ctx = create_parent_invocation_context("test_run_async", sequential_agent)

    events = Enum.to_list(SequentialAgent.run_async(sequential_agent, parent_ctx))

    assert length(events) == 2
    assert hd(events).author == agent_1.name
    assert hd(tl(events)).author == agent_2.name
    assert hd(hd(events).content.parts).text == "Hello, async #{agent_1.name}!"
    assert hd(hd(tl(events)).content.parts).text == "Hello, async #{agent_2.name}!"
  end

  test "run_async_skip_if_no_sub_agent" do
    sequential_agent = %SequentialAgent{
      name: "test_run_async_skip_if_no_sub_agent_test_agent",
      sub_agents: []
    }
    parent_ctx = create_parent_invocation_context("test_run_async_skip_if_no_sub_agent", sequential_agent)

    events = Enum.to_list(SequentialAgent.run_async(sequential_agent, parent_ctx))

    assert length(events) == 0
  end

  test "run_async_with_resumability" do
    agent_1 = %TestingAgent{name: "test_run_async_with_resumability_test_agent_1"}
    agent_2 = %TestingAgent{name: "test_run_async_with_resumability_test_agent_2"}
    sequential_agent = %SequentialAgent{
      name: "test_run_async_with_resumability_test_agent",
      sub_agents: [agent_1, agent_2]
    }
    parent_ctx = create_parent_invocation_context("test_run_async_with_resumability", sequential_agent, true)

    events = Enum.to_list(SequentialAgent.run_async(sequential_agent, parent_ctx))

    assert length(events) == 5
    assert Enum.at(events, 0).author == sequential_agent.name
    refute Enum.at(events, 0).actions.end_of_agent
    assert Enum.at(events, 0).actions.agent_state["current_sub_agent"] == agent_1.name

    assert Enum.at(events, 1).author == agent_1.name
    assert hd(Enum.at(events, 1).content.parts).text == "Hello, async #{agent_1.name}!"

    assert Enum.at(events, 2).author == sequential_agent.name
    refute Enum.at(events, 2).actions.end_of_agent
    assert Enum.at(events, 2).actions.agent_state["current_sub_agent"] == agent_2.name

    assert Enum.at(events, 3).author == agent_2.name
    assert hd(Enum.at(events, 3).content.parts).text == "Hello, async #{agent_2.name}!"

    assert Enum.at(events, 4).author == sequential_agent.name
    assert Enum.at(events, 4).actions.end_of_agent
  end

  test "resume_async" do
    agent_1 = %TestingAgent{name: "test_resume_async_test_agent_1"}
    agent_2 = %TestingAgent{name: "test_resume_async_test_agent_2"}
    sequential_agent = %SequentialAgent{
      name: "test_resume_async_test_agent",
      sub_agents: [agent_1, agent_2]
    }
    parent_ctx = create_parent_invocation_context("test_resume_async", sequential_agent, true)
    parent_ctx = %{parent_ctx | agent_states: %{sequential_agent.name => %SequentialAgentState{current_sub_agent: agent_2.name}}}


    events = Enum.to_list(SequentialAgent.run_async(sequential_agent, parent_ctx))

    assert length(events) == 2
    assert hd(events).author == agent_2.name
    assert hd(hd(events).content.parts).text == "Hello, async #{agent_2.name}!"

    assert hd(tl(events)).author == sequential_agent.name
    assert hd(tl(events)).actions.end_of_agent
  end

  test "run_live" do
    agent_1 = %TestingAgent{name: "test_run_live_test_agent_1"}
    agent_2 = %TestingAgent{name: "test_run_live_test_agent_2"}
    sequential_agent = %SequentialAgent{
      name: "test_run_live_test_agent",
      sub_agents: [agent_1, agent_2]
    }
    parent_ctx = create_parent_invocation_context("test_run_live", sequential_agent)

    events = Enum.to_list(SequentialAgent.run_live(sequential_agent, parent_ctx))

    assert length(events) == 2
    assert hd(events).author == agent_1.name
    assert hd(tl(events)).author == agent_2.name
    assert hd(hd(events).content.parts).text == "Hello, live #{agent_1.name}!"
    assert hd(hd(tl(events)).content.parts).text == "Hello, live #{agent_2.name}!"
  end
end
