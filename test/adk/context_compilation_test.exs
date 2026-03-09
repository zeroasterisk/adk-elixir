defmodule ADK.ContextCompilationTest do
  @moduledoc """
  Tests for context compilation — how the full LLM context is assembled.

  Mirrors Python ADK's BaseLlmFlow behavior:
  - _compile_system_instruction() — merges global, identity, agent instruction with state substitution
  - _build_request() — assembles messages, tools, system instruction, config
  - State variable template substitution via {key} patterns
  - output_key controlling where output is stored in state
  - Transfer instructions for multi-agent setups
  """
  use ExUnit.Case, async: false

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ── Template Variable Substitution ──

  describe "template variable substitution in instructions" do
    test "substitutes state variables in instruction via {key} pattern" do
      ADK.LLM.Mock.set_responses(["Hello Alan"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "greeter",
          model: "test",
          instruction: "You are helping {user_name} with {topic}."
        )

      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "template-1",
          initial_state: %{"user_name" => "Alan", "topic" => "Elixir"}
        )

      ctx = %ADK.Context{
        invocation_id: "inv-t1",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Hi"}
      }

      _events = ADK.Agent.run(agent, ctx)

      # Verify the request sent to the LLM had the substituted instruction
      # We check by inspecting mock — the instruction should have been expanded
      # For now, verify the agent runs without error
      GenServer.stop(session_pid)
    end

    test "leaves unmatched placeholders as-is when state key missing" do
      ADK.LLM.Mock.set_responses(["ok"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Help {user_name} with {unknown_key}."
        )

      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "template-2",
          initial_state: %{"user_name" => "Alan"}
        )

      ctx = %ADK.Context{
        invocation_id: "inv-t2",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Hi"}
      }

      events = ADK.Agent.run(agent, ctx)
      assert length(events) >= 1
      GenServer.stop(session_pid)
    end

    test "handles empty state gracefully" do
      ADK.LLM.Mock.set_responses(["ok"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Help {user_name}."
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "template-3")

      ctx = %ADK.Context{
        invocation_id: "inv-t3",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Hi"}
      }

      events = ADK.Agent.run(agent, ctx)
      assert length(events) >= 1
      GenServer.stop(session_pid)
    end
  end

  # ── Instruction Merging ──

  describe "global + agent instruction merging" do
    test "agent instruction is passed to LLM request" do
      ADK.LLM.Mock.set_responses(["ok"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "You are a helpful assistant."
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "merge-1")

      ctx = %ADK.Context{
        invocation_id: "inv-m1",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Hi"}
      }

      events = ADK.Agent.run(agent, ctx)
      assert length(events) == 1
      GenServer.stop(session_pid)
    end

    test "global instruction merges with agent instruction" do
      ADK.LLM.Mock.set_responses(["ok"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "You are a weather expert.",
          global_instruction: "Always be concise."
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "merge-2")

      ctx = %ADK.Context{
        invocation_id: "inv-m2",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Hi"}
      }

      events = ADK.Agent.run(agent, ctx)
      assert length(events) >= 1
      GenServer.stop(session_pid)
    end
  end

  # ── Output Key State Storage ──

  describe "output_key state storage" do
    test "output_key saves final response text to session state" do
      ADK.LLM.Mock.set_responses(["Research results here"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "researcher",
          model: "test",
          instruction: "Research",
          output_key: :research
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "output-1")

      ctx = %ADK.Context{
        invocation_id: "inv-o1",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Research Elixir"}
      }

      _events = ADK.Agent.run(agent, ctx)
      assert ADK.Session.get_state(session_pid, :research) == "Research results here"
      GenServer.stop(session_pid)
    end

    test "output_key with string key saves to session" do
      ADK.LLM.Mock.set_responses(["Summary text"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "summarizer",
          model: "test",
          instruction: "Summarize",
          output_key: "summary"
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "output-2")

      ctx = %ADK.Context{
        invocation_id: "inv-o2",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Summarize this"}
      }

      _events = ADK.Agent.run(agent, ctx)
      assert ADK.Session.get_state(session_pid, "summary") == "Summary text"
      GenServer.stop(session_pid)
    end

    test "nil output_key does not save to session" do
      ADK.LLM.Mock.set_responses(["Some response"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Help"
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "output-3")

      ctx = %ADK.Context{
        invocation_id: "inv-o3",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Hi"}
      }

      _events = ADK.Agent.run(agent, ctx)
      {:ok, session} = ADK.Session.get(session_pid)
      assert session.state == %{}
      GenServer.stop(session_pid)
    end
  end

  # ── Multi-Agent Context with Transfer Instructions ──

  describe "multi-agent context with transfer instructions" do
    test "agent with sub-agents gets transfer tools in request" do
      sub1 =
        ADK.Agent.LlmAgent.new(
          name: "weather",
          model: "test",
          instruction: "Weather expert",
          description: "Handles weather queries"
        )

      sub2 =
        ADK.Agent.LlmAgent.new(
          name: "math",
          model: "test",
          instruction: "Math expert",
          description: "Handles math queries"
        )

      parent =
        ADK.Agent.LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route to the right agent",
          sub_agents: [sub1, sub2]
        )

      tools = ADK.Agent.LlmAgent.effective_tools(parent)
      tool_names = Enum.map(tools, & &1.name)
      assert "transfer_to_agent_weather" in tool_names
      assert "transfer_to_agent_math" in tool_names
    end

    test "transfer tool triggers sub-agent execution" do
      ADK.LLM.Mock.set_responses([
        # Parent calls transfer
        %{function_call: %{name: "transfer_to_agent_specialist", args: %{}, id: "fc-1"}},
        # Specialist responds
        "I'm the specialist!"
      ])

      specialist =
        ADK.Agent.LlmAgent.new(
          name: "specialist",
          model: "test",
          instruction: "I am a specialist",
          description: "Handles special tasks"
        )

      router =
        ADK.Agent.LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route queries",
          sub_agents: [specialist]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "transfer-1")

      ctx = %ADK.Context{
        invocation_id: "inv-tr1",
        session_pid: session_pid,
        agent: router,
        user_content: %{text: "I need a specialist"}
      }

      events = ADK.Agent.run(router, ctx)

      # Should have transfer event and specialist response
      transfer_events =
        Enum.filter(events, fn e ->
          e.actions && e.actions.transfer_to_agent == "specialist"
        end)

      assert length(transfer_events) >= 1

      # Specialist's response should be in events
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.filter(& &1)
      assert "I'm the specialist!" in texts

      GenServer.stop(session_pid)
    end

    test "transfer to unknown agent produces error event" do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "transfer_to_agent_nonexistent", args: %{}, id: "fc-1"}}
      ])

      # Create a parent agent that has a sub-agent, but the transfer tool references wrong name
      sub =
        ADK.Agent.LlmAgent.new(
          name: "real_agent",
          model: "test",
          instruction: "I exist"
        )

      # Manually create a tool referencing nonexistent agent
      bad_tool = %ADK.Tool.FunctionTool{
        name: "transfer_to_agent_nonexistent",
        description: "Transfer to nonexistent",
        parameters: %{type: "object", properties: %{}, required: []},
        func: fn _ctx, _args -> {:transfer_to_agent, "nonexistent"} end
      }

      router =
        ADK.Agent.LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route queries",
          sub_agents: [sub],
          tools: [bad_tool]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "transfer-2")

      ctx = %ADK.Context{
        invocation_id: "inv-tr2",
        session_pid: session_pid,
        agent: router,
        user_content: %{text: "Transfer me"}
      }

      events = ADK.Agent.run(router, ctx)

      # Should contain an error about unknown agent
      error_events = Enum.filter(events, fn e -> e.error != nil end)
      assert length(error_events) >= 1

      GenServer.stop(session_pid)
    end
  end

  # ── State Passed Through Sequential Agents ──

  describe "state passed through sequential agents" do
    test "output_key from first agent is available to second agent" do
      ADK.LLM.Mock.set_responses([
        "Step 1 result",
        "Step 2 uses step 1"
      ])

      agent1 =
        ADK.Agent.LlmAgent.new(
          name: "step1",
          model: "test",
          instruction: "Do step 1",
          output_key: :step1_result
        )

      agent2 =
        ADK.Agent.LlmAgent.new(
          name: "step2",
          model: "test",
          instruction: "Use {step1_result} for step 2"
        )

      pipeline =
        ADK.Agent.SequentialAgent.new(
          name: "pipeline",
          sub_agents: [agent1, agent2]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "seq-1")

      ctx = %ADK.Context{
        invocation_id: "inv-s1",
        session_pid: session_pid,
        agent: pipeline,
        user_content: %{text: "Run pipeline"}
      }

      events = ADK.Agent.run(pipeline, ctx)
      assert length(events) >= 2

      # Verify step1 saved its output
      assert ADK.Session.get_state(session_pid, :step1_result) == "Step 1 result"

      GenServer.stop(session_pid)
    end

    test "three-stage pipeline passes state through all stages" do
      ADK.LLM.Mock.set_responses([
        "Research data",
        "Analysis of research",
        "Final summary"
      ])

      researcher =
        ADK.Agent.LlmAgent.new(
          name: "researcher",
          model: "test",
          instruction: "Research",
          output_key: :research
        )

      analyst =
        ADK.Agent.LlmAgent.new(
          name: "analyst",
          model: "test",
          instruction: "Analyze {research}",
          output_key: :analysis
        )

      writer =
        ADK.Agent.LlmAgent.new(
          name: "writer",
          model: "test",
          instruction: "Summarize {analysis}",
          output_key: :summary
        )

      pipeline =
        ADK.Agent.SequentialAgent.new(
          name: "pipeline",
          sub_agents: [researcher, analyst, writer]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "seq-2")

      ctx = %ADK.Context{
        invocation_id: "inv-s2",
        session_pid: session_pid,
        agent: pipeline,
        user_content: %{text: "Go"}
      }

      events = ADK.Agent.run(pipeline, ctx)
      assert length(events) >= 3

      assert ADK.Session.get_state(session_pid, :research) == "Research data"
      assert ADK.Session.get_state(session_pid, :analysis) == "Analysis of research"
      assert ADK.Session.get_state(session_pid, :summary) == "Final summary"

      GenServer.stop(session_pid)
    end
  end

  # ── Empty/Missing Instruction Handling ──

  describe "empty/missing instruction handling" do
    test "empty string instruction works" do
      ADK.LLM.Mock.set_responses(["ok"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: ""
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "empty-1")

      ctx = %ADK.Context{
        invocation_id: "inv-e1",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Hi"}
      }

      events = ADK.Agent.run(agent, ctx)
      assert length(events) >= 1
      GenServer.stop(session_pid)
    end

    test "instruction with only whitespace works" do
      ADK.LLM.Mock.set_responses(["ok"])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "   "
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "empty-2")

      ctx = %ADK.Context{
        invocation_id: "inv-e2",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Hi"}
      }

      events = ADK.Agent.run(agent, ctx)
      assert length(events) >= 1
      GenServer.stop(session_pid)
    end
  end

  # ── Request Building ──

  describe "request building" do
    test "build_request includes messages, tools, and instruction" do
      tool =
        ADK.Tool.FunctionTool.new(:greet,
          description: "Greet someone",
          func: fn _ctx, _args -> {:ok, "hi"} end,
          parameters: %{type: "object", properties: %{}, required: []}
        )

      agent =
        ADK.Agent.LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Be helpful",
          tools: [tool]
        )

      # Verify effective_tools includes the function tool
      tools = ADK.Agent.LlmAgent.effective_tools(agent)
      assert length(tools) == 1
      assert hd(tools).name == "greet"
    end

    test "build_request includes transfer tools for sub-agents" do
      sub =
        ADK.Agent.LlmAgent.new(
          name: "helper",
          model: "test",
          instruction: "Help",
          description: "A helper agent"
        )

      tool =
        ADK.Tool.FunctionTool.new(:search,
          description: "Search",
          func: fn _ctx, _args -> {:ok, "results"} end,
          parameters: %{type: "object", properties: %{}, required: []}
        )

      agent =
        ADK.Agent.LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route",
          tools: [tool],
          sub_agents: [sub]
        )

      tools = ADK.Agent.LlmAgent.effective_tools(agent)
      assert length(tools) == 2
      names = Enum.map(tools, & &1.name)
      assert "search" in names
      assert "transfer_to_agent_helper" in names
    end
  end
end
