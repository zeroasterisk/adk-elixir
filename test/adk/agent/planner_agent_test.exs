defmodule ADK.Agent.PlannerAgentTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.Planner.PlanReAct
  alias ADK.Planner.BuiltIn

  test "LlmAgent correctly applies BuiltInPlanner" do
    planner = %BuiltIn{thinking_config: %{thinking_budget: 1024}}

    agent =
      LlmAgent.new(
        name: "planner_agent",
        model: "test_model",
        instruction: "Do it",
        planner: planner
      )

    ctx = %ADK.Context{agent: agent}
    request = ADK.Agent.LlmAgent.build_request(ctx, agent)

    assert request.generate_config.thinking_config.thinking_budget == 1024
  end

  test "LlmAgent correctly applies PlanReActPlanner" do
    planner = %PlanReAct{}

    agent =
      LlmAgent.new(
        name: "planner_agent",
        model: "test_model",
        instruction: "Be helpful",
        planner: planner
      )

    ctx = %ADK.Context{agent: agent}
    request = ADK.Agent.LlmAgent.build_request(ctx, agent)

    # It should inject the planning instruction
    assert request.instruction =~ "Be helpful"
    assert request.instruction =~ "/*PLANNING*/"
    assert request.dynamic_system_instruction =~ "/*PLANNING*/"
  end

  test "LlmAgent with PlanReAct strips 'thought' from history" do
    planner = %PlanReAct{}

    agent =
      LlmAgent.new(
        name: "planner_agent",
        model: "test_model",
        instruction: "Be helpful",
        planner: planner
      )

    {:ok, session_pid} = ADK.Session.start_link(agent: agent)
    ctx = %ADK.Context{agent: agent, session_pid: session_pid}

    ADK.Session.append_event(
      session_pid,
      ADK.Event.new(%{
        author: "user",
        content: %{parts: [%{text: "hi", thought: true}]}
      })
    )

    request = ADK.Agent.LlmAgent.build_request(ctx, agent)

    assert length(request.messages) == 1
    part = Enum.at(Enum.at(request.messages, 0).parts, 0)
    assert part.text == "hi"
    assert Map.get(part, :thought) == nil
  end
end
