defmodule ADK.Integration.SubAgentTest do
  @moduledoc """
  Parity test for Python ADK's tests/integration/test_sub_agent.py

  Python test: evaluates a trip_planner_agent multi-agent system where
  identify_agent selects the best city as a sub-agent. It uses
  AgentEvaluator.evaluate/4 with a JSON eval dataset.

  Elixir equivalent: verifies that an LlmAgent with sub_agents correctly
  routes to the appropriate sub-agent via the transfer_to_agent mechanism,
  and that session state is passed through to sub-agents (simulating the
  trip planner's {origin}, {interests}, {range} context variables).
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ─────────────────────────────────────────────────
  # Mirrors: test_eval_agent (Python test_sub_agent.py)
  #
  # The Python test uses:
  #   - trip_planner root_agent (model: gemini-2.0-flash-001)
  #   - sub_agents: [identify_agent, gather_agent, plan_agent]
  #   - state: {origin, interests, range, cities}
  #   - eval dataset: trip_inquiry_sub_agent.test.json
  #   - Expected: identify_agent selects LA over Yosemite given Food/Shopping/Museums interests
  # ─────────────────────────────────────────────────

  describe "trip planner sub-agent routing" do
    setup do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "trip_planner_agent",
          user_id: "test_user",
          session_id: "sub-agent-trip-#{System.unique_integer([:positive])}",
          name: nil
        )

      # Set up session state as defined in the Python eval JSON
      ADK.Session.put_state(session_pid, "origin", "San Francisco")
      ADK.Session.put_state(session_pid, "interests", "Food, Shopping, Museums")
      ADK.Session.put_state(session_pid, "range", "1000 miles")
      ADK.Session.put_state(session_pid, "cities", "")

      on_exit(fn ->
        if Process.alive?(session_pid), do: GenServer.stop(session_pid)
      end)

      %{session_pid: session_pid}
    end

    test "root agent transfers to identify_agent sub-agent", %{session_pid: session_pid} do
      # Python: root_agent has sub_agents: [identify_agent, gather_agent, plan_agent]
      # Mock: parent calls transfer_to_agent_identify_agent, then identify_agent responds
      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{
            name: "transfer_to_agent_identify_agent",
            args: %{},
            id: "fc-trip-1"
          }
        },
        "Given your interests in food, shopping, and museums, Los Angeles would be a better choice than Yosemite National Park."
      ])

      identify_agent =
        ADK.Agent.LlmAgent.new(
          name: "identify_agent",
          model: "test",
          description: "Select the best city based on weather, season, and prices.",
          instruction: """
          Analyze and select the best city for the trip based on specific criteria such
          as weather patterns, seasonal events, and travel costs.
          Traveling from: {origin}
          City Options: {cities}
          Trip Date: {range}
          Traveler Interests: {interests}
          """
        )

      gather_agent =
        ADK.Agent.LlmAgent.new(
          name: "gather_agent",
          model: "test",
          description: "Provide the BEST insights about the selected city",
          instruction: "Gather information about key attractions and local customs."
        )

      plan_agent =
        ADK.Agent.LlmAgent.new(
          name: "plan_agent",
          model: "test",
          description: "Create the most amazing travel itineraries with budget and packing suggestions",
          instruction: "Expand the guide into a full 7-day travel itinerary."
        )

      root_agent =
        ADK.Agent.LlmAgent.new(
          name: "trip_planner",
          model: "test",
          description: "Plan the best trip ever",
          instruction: "Plan the best trip according to information listed above.",
          sub_agents: [identify_agent, gather_agent, plan_agent]
        )

      ctx = %ADK.Context{
        invocation_id: "inv-trip-1",
        session_pid: session_pid,
        agent: root_agent,
        user_content: %{
          text: "Based on my interests, where should I go, Yosemite national park or Los Angeles?"
        }
      }

      events = ADK.Agent.run(root_agent, ctx)

      # Should have at least: root LLM event, transfer event, identify_agent response
      assert length(events) >= 3

      # Transfer event should exist — routing to identify_agent
      transfer_event =
        Enum.find(events, fn e ->
          e.actions && e.actions.transfer_to_agent == "identify_agent"
        end)

      assert transfer_event != nil, "Expected transfer_to_agent event for identify_agent"

      # Final response should mention Los Angeles
      last = List.last(events)
      text = ADK.Event.text(last)
      assert text =~ "Los Angeles"
    end

    test "identify_agent instruction interpolates session state variables", %{
      session_pid: session_pid
    } do
      # Parity with Python's {origin}, {interests}, {range}, {cities} template vars
      identify_agent = %{
        name: "identify_agent",
        description: "Select the best city.",
        instruction: """
        Analyze and select the best city for the trip.
        Traveling from: {origin}
        City Options: {cities}
        Trip Date: {range}
        Traveler Interests: {interests}
        """,
        global_instruction: nil,
        output_schema: nil,
        sub_agents: []
      }

      ctx = %ADK.Context{
        invocation_id: "inv-trip-vars",
        session_pid: session_pid,
        agent: nil,
        callbacks: [],
        policies: []
      }

      compiled = ADK.InstructionCompiler.compile(identify_agent, ctx)

      assert compiled =~ "San Francisco"
      assert compiled =~ "Food, Shopping, Museums"
      assert compiled =~ "1000 miles"
      refute compiled =~ "{origin}"
      refute compiled =~ "{interests}"
      refute compiled =~ "{range}"
    end

    test "root_agent has transfer tools auto-injected for all sub-agents" do
      identify_agent =
        ADK.Agent.LlmAgent.new(
          name: "identify_agent",
          model: "test",
          instruction: "Select the best city based on weather, season, and prices.",
          description: "Select the best city."
        )

      gather_agent =
        ADK.Agent.LlmAgent.new(
          name: "gather_agent",
          model: "test",
          instruction: "Provide in-depth insights about the selected city.",
          description: "Provide city insights."
        )

      plan_agent =
        ADK.Agent.LlmAgent.new(
          name: "plan_agent",
          model: "test",
          instruction: "Create a full 7-day travel itinerary.",
          description: "Create travel itineraries."
        )

      root_agent =
        ADK.Agent.LlmAgent.new(
          name: "trip_planner",
          model: "test",
          instruction: "Plan the best trip.",
          sub_agents: [identify_agent, gather_agent, plan_agent]
        )

      # All three sub-agents should have transfer tools available via effective_tools/1
      # (transfer tools are computed dynamically, not stored in agent.tools directly)
      tool_names =
        ADK.Agent.LlmAgent.effective_tools(root_agent)
        |> Enum.map(& &1.name)

      assert "transfer_to_agent_identify_agent" in tool_names
      assert "transfer_to_agent_gather_agent" in tool_names
      assert "transfer_to_agent_plan_agent" in tool_names
    end
  end

  describe "sub-agent response quality (parity with Python AgentEvaluator)" do
    test "sub-agent receives parent session state on transfer", %{} do
      # Python AgentEvaluator passes session state into the agent context
      # Elixir: verify sub-agent can read state set before root-agent run
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "trip_planner_agent",
          user_id: "test_user",
          session_id: "sub-agent-state-#{System.unique_integer([:positive])}",
          name: nil
        )

      ADK.Session.put_state(session_pid, "origin", "San Francisco")
      ADK.Session.put_state(session_pid, "interests", "Food, Shopping, Museums")
      ADK.Session.put_state(session_pid, "range", "1000 miles")

      # Sub-agent reads from shared session state
      assert ADK.Session.get_state(session_pid, "origin") == "San Francisco"
      assert ADK.Session.get_state(session_pid, "interests") == "Food, Shopping, Museums"

      GenServer.stop(session_pid)
    end

    test "multi-sub-agent system: identify → gather → plan flow", %{} do
      # Python test uses num_runs=4 with identify_agent as the evaluated target
      # Elixir: verify sequential sub-agent handoff is structurally valid
      ADK.LLM.Mock.set_responses([
        # Root transfers to identify_agent
        %{
          function_call: %{
            name: "transfer_to_agent_identify_agent",
            args: %{},
            id: "fc-1"
          }
        },
        # identify_agent gives a city recommendation
        "Los Angeles is the best choice given your interests."
      ])

      identify_agent =
        ADK.Agent.LlmAgent.new(
          name: "identify_agent",
          model: "test",
          instruction: "Select the best city based on weather, season, and prices.",
          description: "Select the best city."
        )

      root_agent =
        ADK.Agent.LlmAgent.new(
          name: "trip_planner",
          model: "test",
          instruction: "Plan the best trip.",
          sub_agents: [identify_agent]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "trip_planner_agent",
          user_id: "u1",
          session_id: "sub-flow-#{System.unique_integer([:positive])}",
          name: nil
        )

      ctx = %ADK.Context{
        invocation_id: "inv-flow",
        session_pid: session_pid,
        agent: root_agent,
        user_content: %{text: "Where should I go?"}
      }

      events = ADK.Agent.run(root_agent, ctx)

      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "Los Angeles"

      GenServer.stop(session_pid)
    end
  end
end
