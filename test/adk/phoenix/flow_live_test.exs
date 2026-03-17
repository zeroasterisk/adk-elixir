defmodule ADK.Phoenix.FlowLiveTest do
  use ExUnit.Case, async: true

  alias ADK.Phoenix.FlowLive
  alias ADK.Agent.{LlmAgent, SequentialAgent, ParallelAgent, LoopAgent, Custom}

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  # ── Helpers ───────────────────────────────────────────────────────────

  defp render_flow(agent, opts \\ []) do
    active = Keyword.get(opts, :active_agent, nil)
    assigns = %{agent: agent, active_agent: active}
    rendered_to_string(FlowLive.flow_graph(assigns))
  end

  # ── Single LlmAgent ──────────────────────────────────────────────────

  describe "single LlmAgent" do
    test "renders agent name and type badge" do
      agent = LlmAgent.new(name: "researcher", model: "gemini-2.0-flash")
      html = render_flow(agent)

      assert html =~ "researcher"
      assert html =~ "LLM"
      assert html =~ "adk-flow-node"
    end

    test "shows model" do
      agent = LlmAgent.new(name: "bot", model: "gemini-2.0-flash")
      html = render_flow(agent)

      assert html =~ "gemini-2.0-flash"
      assert html =~ "🧠"
    end

    test "shows tool count" do
      tools = [
        %{name: "search", description: "Search the web"},
        %{name: "calc", description: "Calculate"}
      ]

      agent = LlmAgent.new(name: "tool_user", model: "gemini", tools: tools)
      html = render_flow(agent)

      assert html =~ "🔧"
      assert html =~ "2 tools"
    end

    test "single tool shows singular" do
      agent = LlmAgent.new(name: "one_tool", model: "gemini", tools: [%{name: "t"}])
      html = render_flow(agent)

      assert html =~ "1 tool"
      refute html =~ "1 tools"
    end

    test "no tools hides tool section" do
      agent = LlmAgent.new(name: "no_tools", model: "gemini", tools: [])
      html = render_flow(agent)

      refute html =~ "🔧"
    end
  end

  # ── Sequential Agent ──────────────────────────────────────────────────

  describe "Sequential with 2 children" do
    test "renders container with sequential badge" do
      agent =
        SequentialAgent.new(
          name: "pipeline",
          sub_agents: [
            LlmAgent.new(name: "step1", model: "gemini"),
            LlmAgent.new(name: "step2", model: "gemini")
          ]
        )

      html = render_flow(agent)

      assert html =~ "pipeline"
      assert html =~ "Sequential"
      assert html =~ "adk-flow-sequential"
      assert html =~ "step1"
      assert html =~ "step2"
    end

    test "renders arrows between children" do
      agent =
        SequentialAgent.new(
          name: "seq",
          sub_agents: [
            LlmAgent.new(name: "a", model: "m"),
            LlmAgent.new(name: "b", model: "m")
          ]
        )

      html = render_flow(agent)
      assert html =~ "adk-flow-arrow"
      assert html =~ "▼"
    end
  end

  # ── Parallel Agent ────────────────────────────────────────────────────

  describe "Parallel with 3 children" do
    test "renders parallel container with fork/join" do
      agent =
        ParallelAgent.new(
          name: "fan_out",
          sub_agents: [
            LlmAgent.new(name: "r1", model: "m"),
            LlmAgent.new(name: "r2", model: "m"),
            LlmAgent.new(name: "r3", model: "m")
          ]
        )

      html = render_flow(agent)

      assert html =~ "fan_out"
      assert html =~ "Parallel"
      assert html =~ "adk-flow-parallel"
      assert html =~ "r1"
      assert html =~ "r2"
      assert html =~ "r3"
      assert html =~ "fork"
      assert html =~ "join"
    end
  end

  # ── Loop Agent ────────────────────────────────────────────────────────

  describe "Loop with child" do
    test "renders loop container with cycle arrow" do
      agent =
        LoopAgent.new(
          name: "retry",
          max_iterations: 5,
          sub_agents: [
            LlmAgent.new(name: "worker", model: "gemini")
          ]
        )

      html = render_flow(agent)

      assert html =~ "retry"
      assert html =~ "Loop"
      assert html =~ "adk-flow-loop"
      assert html =~ "worker"
      assert html =~ "↻"
      assert html =~ "max: 5"
    end
  end

  # ── Nested ────────────────────────────────────────────────────────────

  describe "nested: Sequential containing Parallel containing agents" do
    test "renders full nested tree" do
      agent =
        SequentialAgent.new(
          name: "outer",
          sub_agents: [
            LlmAgent.new(name: "first", model: "m"),
            ParallelAgent.new(
              name: "middle",
              sub_agents: [
                LlmAgent.new(name: "left", model: "m"),
                LlmAgent.new(name: "right", model: "m")
              ]
            ),
            LlmAgent.new(name: "last", model: "m")
          ]
        )

      html = render_flow(agent)

      # All names present
      assert html =~ "outer"
      assert html =~ "first"
      assert html =~ "middle"
      assert html =~ "left"
      assert html =~ "right"
      assert html =~ "last"

      # Both container types
      assert html =~ "adk-flow-sequential"
      assert html =~ "adk-flow-parallel"
    end
  end

  # ── Active Agent Highlighting ─────────────────────────────────────────

  describe "active agent highlighting" do
    test "highlights active leaf agent" do
      agent = LlmAgent.new(name: "bot", model: "m")
      html = render_flow(agent, active_agent: "bot")

      assert html =~ "active"
      # Active nodes get green border color
      assert html =~ "#22c55e"
    end

    test "does not highlight inactive agent" do
      agent = LlmAgent.new(name: "bot", model: "m")
      html = render_flow(agent, active_agent: "other")

      refute html =~ "active-indicator"
    end

    test "highlights active container" do
      agent =
        SequentialAgent.new(
          name: "pipeline",
          sub_agents: [LlmAgent.new(name: "step1", model: "m")]
        )

      html = render_flow(agent, active_agent: "pipeline")
      assert html =~ "active"
    end

    test "highlights child inside container" do
      agent =
        SequentialAgent.new(
          name: "pipeline",
          sub_agents: [
            LlmAgent.new(name: "step1", model: "m"),
            LlmAgent.new(name: "step2", model: "m")
          ]
        )

      html = render_flow(agent, active_agent: "step2")
      # step2 should have the active indicator
      assert html =~ "active"
    end
  end

  # ── Empty sub_agents ──────────────────────────────────────────────────

  describe "empty sub_agents renders leaf node" do
    test "sequential with no children renders as container with empty body" do
      agent = SequentialAgent.new(name: "empty_seq", sub_agents: [])
      html = render_flow(agent)

      assert html =~ "empty_seq"
      assert html =~ "Sequential"
      # No arrows since no children
      refute html =~ "▼"
    end
  end

  # ── Custom Agent ──────────────────────────────────────────────────────

  describe "Custom agent" do
    test "renders with custom badge" do
      agent = Custom.new(name: "my_custom", run_fn: fn _, _ -> [] end)
      html = render_flow(agent)

      assert html =~ "my_custom"
      assert html =~ "Custom"
    end
  end

  # ── Agent Type Detection ──────────────────────────────────────────────

  describe "agent_type/1" do
    test "identifies all agent types" do
      assert FlowLive.agent_type(%LlmAgent{name: "a"}) == :llm
      assert FlowLive.agent_type(%SequentialAgent{name: "a"}) == :sequential
      assert FlowLive.agent_type(%ParallelAgent{name: "a"}) == :parallel
      assert FlowLive.agent_type(%LoopAgent{name: "a"}) == :loop
      assert FlowLive.agent_type(%Custom{name: "a", run_fn: fn _, _ -> [] end}) == :custom
    end

    test "unknown struct returns :unknown" do
      assert FlowLive.agent_type(%{name: "mystery"}) == :unknown
    end
  end

  # ── Description ───────────────────────────────────────────────────────

  describe "agent description" do
    test "shows description when present" do
      agent = LlmAgent.new(name: "d", model: "m", description: "A helpful bot")
      html = render_flow(agent)

      assert html =~ "A helpful bot"
    end
  end

  # ── Data Attributes ──────────────────────────────────────────────────

  describe "data attributes" do
    test "includes data-agent-name for programmatic access" do
      agent = LlmAgent.new(name: "test_agent", model: "m")
      html = render_flow(agent)

      assert html =~ ~s(data-agent-name="test_agent")
    end
  end
end
