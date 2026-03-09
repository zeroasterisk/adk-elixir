defmodule ADK.TransferE2ETest do
  @moduledoc """
  End-to-end tests for agent transfer (delegation to sub-agents).

  Tests the full flow: LLM calls transfer tool → tool returns signal →
  LlmAgent detects transfer → delegates to target agent → returns response.

  Uses Mock LLM for deterministic behavior.
  """

  use ExUnit.Case, async: false

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # Helper to create a session and context
  defp setup_context(agent, session_id) do
    {:ok, session_pid} =
      ADK.Session.start_link(app_name: "transfer_e2e", user_id: "u1", session_id: session_id)

    ctx = %ADK.Context{
      invocation_id: "inv-#{session_id}",
      session_pid: session_pid,
      agent: agent,
      user_content: %{text: "test message"}
    }

    {session_pid, ctx}
  end

  # ============================================================
  # Basic transfer: parent → sub-agent
  # ============================================================

  describe "basic transfer" do
    test "parent transfers to sub-agent, sub-agent produces final response" do
      ADK.LLM.Mock.set_responses([
        # Parent decides to transfer
        %{function_call: %{name: "transfer_to_agent_helper", args: %{}, id: "fc-1"}},
        # Helper (sub-agent) responds
        "Hello from the helper agent!"
      ])

      helper = ADK.Agent.LlmAgent.new(
        name: "helper",
        model: "test",
        instruction: "You are a helpful assistant.",
        description: "Handles help requests"
      )

      parent = ADK.Agent.LlmAgent.new(
        name: "parent",
        model: "test",
        instruction: "Route requests to the right agent.",
        sub_agents: [helper]
      )

      {session_pid, ctx} = setup_context(parent, "basic-transfer")
      events = ADK.Agent.run(parent, ctx)

      # Verify event structure:
      # 1. Parent's LLM response (with function_call)
      # 2. Transfer event (with actions.transfer_to_agent)
      # 3. Sub-agent's response
      assert length(events) == 3

      [parent_event, transfer_event, helper_event] = events

      # Parent event has the function call
      assert ADK.Event.has_function_calls?(parent_event)
      assert parent_event.author == "parent"

      # Transfer event signals the handoff
      assert transfer_event.actions.transfer_to_agent == "helper"

      # Helper event is the final response
      assert ADK.Event.text(helper_event) == "Hello from the helper agent!"
      assert helper_event.author == "helper"

      GenServer.stop(session_pid)
    end

    test "parent with multiple sub-agents transfers to the correct one" do
      ADK.LLM.Mock.set_responses([
        # Parent transfers to writer (not researcher)
        %{function_call: %{name: "transfer_to_agent_writer", args: %{}, id: "fc-1"}},
        # Writer responds
        "Here's your draft article."
      ])

      researcher = ADK.Agent.LlmAgent.new(
        name: "researcher",
        model: "test",
        instruction: "Research topics.",
        description: "Finds information"
      )

      writer = ADK.Agent.LlmAgent.new(
        name: "writer",
        model: "test",
        instruction: "Write content.",
        description: "Creates written content"
      )

      parent = ADK.Agent.LlmAgent.new(
        name: "coordinator",
        model: "test",
        instruction: "Route to the right specialist.",
        sub_agents: [researcher, writer]
      )

      {session_pid, ctx} = setup_context(parent, "multi-sub")
      events = ADK.Agent.run(parent, ctx)

      last = List.last(events)
      assert ADK.Event.text(last) == "Here's your draft article."
      assert last.author == "writer"

      # Verify transfer event points to writer
      transfer_event = Enum.find(events, &(&1.actions && &1.actions.transfer_to_agent == "writer"))
      assert transfer_event != nil

      GenServer.stop(session_pid)
    end
  end

  # ============================================================
  # Transfer via Runner (full stack)
  # ============================================================

  describe "transfer via Runner" do
    test "Runner.run handles transfer end-to-end" do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "transfer_to_agent_specialist", args: %{}, id: "fc-1"}},
        "Specialist analysis complete."
      ])

      specialist = ADK.Agent.LlmAgent.new(
        name: "specialist",
        model: "test",
        instruction: "Analyze data.",
        description: "Data analysis expert"
      )

      parent = ADK.Agent.LlmAgent.new(
        name: "router",
        model: "test",
        instruction: "Route to specialists.",
        sub_agents: [specialist]
      )

      runner = ADK.Runner.new(app_name: "transfer_e2e", agent: parent)
      events = ADK.Runner.run(runner, "user1", "runner-transfer", "analyze this data")

      last = List.last(events)
      assert ADK.Event.text(last) == "Specialist analysis complete."
      assert last.author == "specialist"
    end
  end

  # ============================================================
  # Multi-hop transfer: A → B → C
  # ============================================================

  describe "multi-hop transfer" do
    test "A transfers to B, B transfers to C, C responds" do
      ADK.LLM.Mock.set_responses([
        # A transfers to B
        %{function_call: %{name: "transfer_to_agent_agent_b", args: %{}, id: "fc-1"}},
        # B transfers to C
        %{function_call: %{name: "transfer_to_agent_agent_c", args: %{}, id: "fc-2"}},
        # C responds
        "Final response from agent C!"
      ])

      agent_c = ADK.Agent.LlmAgent.new(
        name: "agent_c",
        model: "test",
        instruction: "You are agent C.",
        description: "Final handler"
      )

      agent_b = ADK.Agent.LlmAgent.new(
        name: "agent_b",
        model: "test",
        instruction: "You are agent B.",
        description: "Intermediate handler",
        sub_agents: [agent_c]
      )

      agent_a = ADK.Agent.LlmAgent.new(
        name: "agent_a",
        model: "test",
        instruction: "You are agent A.",
        sub_agents: [agent_b]
      )

      {session_pid, ctx} = setup_context(agent_a, "multi-hop")
      events = ADK.Agent.run(agent_a, ctx)

      # Final event should be from agent C
      last = List.last(events)
      assert ADK.Event.text(last) == "Final response from agent C!"
      assert last.author == "agent_c"

      # Should have transfer events for both hops
      transfers = Enum.filter(events, &(&1.actions && &1.actions.transfer_to_agent))
      assert length(transfers) == 2
      assert Enum.map(transfers, & &1.actions.transfer_to_agent) == ["agent_b", "agent_c"]

      GenServer.stop(session_pid)
    end
  end

  # ============================================================
  # Transfer to unknown agent
  # ============================================================

  describe "unknown agent transfer" do
    test "transfer to non-existent agent produces error event" do
      # LLM calls a tool that doesn't exist (no matching sub-agent)
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "transfer_to_agent_ghost", args: %{}, id: "fc-1"}},
        "Fallback response after error."
      ])

      known = ADK.Agent.LlmAgent.new(
        name: "known",
        model: "test",
        instruction: "Help.",
        description: "A known agent"
      )

      parent = ADK.Agent.LlmAgent.new(
        name: "parent",
        model: "test",
        instruction: "Route requests.",
        sub_agents: [known]
      )

      {session_pid, ctx} = setup_context(parent, "unknown-transfer")
      events = ADK.Agent.run(parent, ctx)

      # Should have tool error response then LLM continues
      # The unknown tool error is sent back to LLM, which produces fallback
      assert length(events) >= 2

      # Should eventually get a text response (LLM recovers from tool error)
      last = List.last(events)
      assert ADK.Event.text?(last)

      GenServer.stop(session_pid)
    end
  end

  # ============================================================
  # Sub-agent uses tools before responding
  # ============================================================

  describe "sub-agent with tools" do
    test "transferred sub-agent can use its own tools" do
      ADK.LLM.Mock.set_responses([
        # Parent transfers to researcher
        %{function_call: %{name: "transfer_to_agent_researcher", args: %{}, id: "fc-1"}},
        # Researcher uses its search tool
        %{function_call: %{name: "search", args: %{"query" => "elixir"}, id: "fc-2"}},
        # Researcher gives final answer after tool result
        "Based on my research: Elixir is great!"
      ])

      search_tool = ADK.Tool.FunctionTool.new(:search,
        description: "Search for information",
        func: fn _ctx, %{"query" => q} -> {:ok, "Results for: #{q}"} end,
        parameters: %{
          type: "object",
          properties: %{query: %{type: "string"}},
          required: ["query"]
        }
      )

      researcher = ADK.Agent.LlmAgent.new(
        name: "researcher",
        model: "test",
        instruction: "Research using search.",
        description: "Research agent",
        tools: [search_tool]
      )

      parent = ADK.Agent.LlmAgent.new(
        name: "parent",
        model: "test",
        instruction: "Route requests.",
        sub_agents: [researcher]
      )

      {session_pid, ctx} = setup_context(parent, "sub-with-tools")
      events = ADK.Agent.run(parent, ctx)

      last = List.last(events)
      assert ADK.Event.text(last) =~ "Elixir is great"
      assert last.author == "researcher"

      GenServer.stop(session_pid)
    end
  end

  # ============================================================
  # Session state persists across transfer
  # ============================================================

  describe "session state across transfer" do
    test "sub-agent shares session with parent" do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "transfer_to_agent_helper", args: %{}, id: "fc-1"}},
        "Done!"
      ])

      helper = ADK.Agent.LlmAgent.new(
        name: "helper",
        model: "test",
        instruction: "Help."
      )

      parent = ADK.Agent.LlmAgent.new(
        name: "parent",
        model: "test",
        instruction: "Route.",
        sub_agents: [helper]
      )

      {session_pid, ctx} = setup_context(parent, "shared-session")

      # Set some state before running
      ADK.Session.put_state(session_pid, "key1", "value1")

      _events = ADK.Agent.run(parent, ctx)

      # Session should still be accessible with the state
      {:ok, session} = ADK.Session.get(session_pid)
      assert session.state["key1"] == "value1"

      GenServer.stop(session_pid)
    end
  end

  # ============================================================
  # Transfer tool declarations
  # ============================================================

  describe "transfer tool declarations" do
    test "effective_tools includes per-agent transfer tools in LLM request" do
      sub1 = ADK.Agent.LlmAgent.new(name: "alpha", model: "test", instruction: "A.", description: "Agent alpha")
      sub2 = ADK.Agent.LlmAgent.new(name: "beta", model: "test", instruction: "B.", description: "Agent beta")

      parent = ADK.Agent.LlmAgent.new(
        name: "parent",
        model: "test",
        instruction: "Route.",
        sub_agents: [sub1, sub2]
      )

      tools = ADK.Agent.LlmAgent.effective_tools(parent)
      names = Enum.map(tools, & &1.name)

      assert "transfer_to_agent_alpha" in names
      assert "transfer_to_agent_beta" in names
      assert length(tools) == 2

      # Check declarations have correct structure
      Enum.each(tools, fn tool ->
        decl = ADK.Tool.declaration(tool)
        assert decl.name =~ "transfer_to_agent_"
        assert is_binary(decl.description)
      end)
    end

    test "instruction includes transfer info for sub-agents" do
      sub = ADK.Agent.LlmAgent.new(
        name: "helper",
        model: "test",
        instruction: "Help.",
        description: "A helpful agent"
      )

      parent = ADK.Agent.LlmAgent.new(
        name: "parent",
        model: "test",
        instruction: "Coordinate tasks.",
        sub_agents: [sub]
      )

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: parent}
      instruction = ADK.Agent.LlmAgent.compile_instruction(ctx, parent)

      assert instruction =~ "helper"
      assert instruction =~ "A helpful agent"
      assert instruction =~ "transfer"
    end
  end
end
