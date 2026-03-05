defmodule ADK.ContextTest do
  use ExUnit.Case, async: true
  doctest ADK.Context

  test "fork_branch creates child branch" do
    ctx = %ADK.Context{invocation_id: "inv-1", branch: nil}
    child = ADK.Context.fork_branch(ctx, "search")
    assert child.branch == "search"
    assert child.temp_state == %{}
  end

  test "fork_branch nests branches" do
    ctx = %ADK.Context{invocation_id: "inv-1", branch: "parent"}
    child = ADK.Context.fork_branch(ctx, "child")
    assert child.branch == "parent.child"
  end

  test "temp state operations" do
    ctx = %ADK.Context{invocation_id: "inv-1"}
    ctx = ADK.Context.put_temp(ctx, :key, "value")
    assert ADK.Context.get_temp(ctx, :key) == "value"
    assert ADK.Context.get_temp(ctx, :missing) == nil
  end

  test "for_child sets agent and clears temp" do
    ctx = %ADK.Context{invocation_id: "inv-1", temp_state: %{x: 1}}
    agent = %{name: "child", module: ADK.Agent.LlmAgent}
    child = ADK.Context.for_child(ctx, agent)
    assert child.agent == agent
    assert child.temp_state == %{}
  end
end
