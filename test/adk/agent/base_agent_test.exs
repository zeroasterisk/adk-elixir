defmodule ADK.Agent.BaseAgentTest do
  @moduledoc """
  Parity tests for Python ADK's test_base_agent.py.

  Covers agent hierarchy, callbacks (before/after, chains), basic runs,
  and agent tree search.
  """
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.Agent.Custom
  alias ADK.Event
  alias ADK.Runner

  # ---------------------------------------------------------------------------
  # Callback modules
  # ---------------------------------------------------------------------------

  defmodule NoopBeforeAgent do
    @behaviour ADK.Callback
    @impl true
    def before_agent(ctx), do: {:cont, ctx}
  end

  defmodule HaltBeforeAgent do
    @behaviour ADK.Callback
    @impl true
    def before_agent(_ctx) do
      {:halt, [Event.new(%{author: "callback", content: %{parts: [%{text: "halted by before_agent"}]}})]}
    end
  end

  defmodule NoopAfterAgent do
    @behaviour ADK.Callback
    @impl true
    def after_agent(events, _ctx), do: events
  end

  defmodule AppendAfterAgent do
    @behaviour ADK.Callback
    @impl true
    def after_agent(events, _ctx) do
      extra = Event.new(%{author: "callback", content: %{parts: [%{text: "appended by after_agent"}]}})
      events ++ [extra]
    end
  end

  # For chain tests: first halter wins, second never runs
  defmodule HaltBeforeAgentA do
    @behaviour ADK.Callback
    @impl true
    def before_agent(_ctx) do
      {:halt, [Event.new(%{author: "callback_a", content: %{parts: [%{text: "halted by A"}]}})]}
    end
  end

  defmodule HaltBeforeAgentB do
    @behaviour ADK.Callback
    @impl true
    def before_agent(_ctx) do
      {:halt, [Event.new(%{author: "callback_b", content: %{parts: [%{text: "halted by B"}]}})]}
    end
  end

  defmodule ContinueBeforeAgent do
    @behaviour ADK.Callback
    @impl true
    def before_agent(ctx), do: {:cont, ctx}
  end

  defmodule AppendAfterAgentA do
    @behaviour ADK.Callback
    @impl true
    def after_agent(events, _ctx) do
      events ++ [Event.new(%{author: "after_a", content: %{parts: [%{text: "from A"}]}})]
    end
  end

  defmodule AppendAfterAgentB do
    @behaviour ADK.Callback
    @impl true
    def after_agent(events, _ctx) do
      events ++ [Event.new(%{author: "after_b", content: %{parts: [%{text: "from B"}]}})]
    end
  end

  # ---------------------------------------------------------------------------
  # Agent Hierarchy Tests
  # ---------------------------------------------------------------------------

  describe "agent hierarchy" do
    test "parent_agent is wired on sub-agents when using LlmAgent.new" do
      child = LlmAgent.new(name: "child", model: "mock", instruction: "I'm a child")
      parent = LlmAgent.new(name: "parent", model: "mock", instruction: "I'm a parent", sub_agents: [child])

      [wired_child] = parent.sub_agents
      assert wired_child.parent_agent.name == "parent"
    end

    test "parent_agent is nil for root agent" do
      root = LlmAgent.new(name: "root", model: "mock", instruction: "I'm root")
      assert root.parent_agent == nil
    end

    test "nested hierarchy wires parent at each level" do
      grandchild = LlmAgent.new(name: "grandchild", model: "mock", instruction: "gc")
      child = LlmAgent.new(name: "child", model: "mock", instruction: "c", sub_agents: [grandchild])
      root = LlmAgent.new(name: "root", model: "mock", instruction: "r", sub_agents: [child])

      [wired_child] = root.sub_agents
      assert wired_child.parent_agent.name == "root"

      [wired_grandchild] = wired_child.sub_agents
      assert wired_grandchild.parent_agent.name == "child"
    end

    test "root_agent traversal walks up parent chain" do
      # In Elixir's immutable world, parent wiring happens at each LlmAgent.new call.
      # The grandchild's parent_agent points to the child *before* it was itself wired
      # to the root. So we verify each level's immediate parent is correct.
      grandchild = LlmAgent.new(name: "gc", model: "mock", instruction: "gc")
      child = LlmAgent.new(name: "c", model: "mock", instruction: "c", sub_agents: [grandchild])
      root = LlmAgent.new(name: "root", model: "mock", instruction: "r", sub_agents: [child])

      # Walk from root down
      [wired_child] = root.sub_agents
      assert wired_child.parent_agent.name == "root"

      [wired_gc] = wired_child.sub_agents
      # gc's parent was wired when child was created (before root existed)
      assert wired_gc.parent_agent.name == "c"

      # root has no parent
      assert root.parent_agent == nil
    end

    test "multiple sub-agents all get parent wired" do
      c1 = LlmAgent.new(name: "c1", model: "mock", instruction: "c1")
      c2 = LlmAgent.new(name: "c2", model: "mock", instruction: "c2")
      parent = LlmAgent.new(name: "parent", model: "mock", instruction: "p", sub_agents: [c1, c2])

      assert length(parent.sub_agents) == 2
      Enum.each(parent.sub_agents, fn sub ->
        assert sub.parent_agent.name == "parent"
      end)
    end

    test "find_active_agent returns root when no transfers" do
      agent = LlmAgent.new(name: "root", model: "mock", instruction: "hi")
      # With nil session_pid, should return root
      assert Runner.find_active_agent(agent, nil) == agent
    end

    test "find_active_agent finds transferred sub-agent" do
      sub = LlmAgent.new(name: "helper", model: "mock", instruction: "help")
      root = LlmAgent.new(name: "root", model: "mock", instruction: "hi", sub_agents: [sub])

      # Start a session, add a transfer event
      {:ok, session_pid} = ADK.Session.start_link(
        app_name: "test_find",
        user_id: "u1",
        session_id: "s_find_#{System.unique_integer([:positive])}"
      )

      transfer_event = Event.new(%{
        author: "root",
        content: %{parts: [%{text: "transferring"}]},
        actions: %ADK.EventActions{transfer_to_agent: "helper"}
      })
      ADK.Session.append_event(session_pid, transfer_event)

      active = Runner.find_active_agent(root, session_pid)
      assert ADK.Agent.name(active) == "helper"

      GenServer.stop(session_pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Basic Run Tests
  # ---------------------------------------------------------------------------

  describe "basic run" do
    test "custom agent produces events with correct author and content" do
      agent = Custom.new(
        name: "greeter",
        run_fn: fn _agent, _ctx ->
          [Event.new(%{author: "greeter", content: %{parts: [%{text: "hello world"}]}})]
        end
      )

      runner = Runner.new(app_name: "test_basic", agent: agent)
      events = Runner.run(runner, "user1", "s_basic_#{System.unique_integer([:positive])}", "hi")

      assert length(events) == 1
      [event] = events
      assert event.author == "greeter"
      assert Event.text(event) == "hello world"
    end

    test "LlmAgent with mock LLM produces expected output" do
      ADK.LLM.Mock.set_responses(["mock reply"])

      agent = LlmAgent.new(name: "llm_bot", model: "mock", instruction: "You are helpful.")
      runner = Runner.new(app_name: "test_llm", agent: agent)
      events = Runner.run(runner, "user1", "s_llm_#{System.unique_integer([:positive])}", "hello")

      assert length(events) >= 1
      texts = Enum.map(events, &Event.text/1) |> Enum.filter(& &1)
      assert "mock reply" in texts
    end

    test "custom agent can produce multiple events" do
      agent = Custom.new(
        name: "multi",
        run_fn: fn _agent, _ctx ->
          [
            Event.new(%{author: "multi", content: %{parts: [%{text: "first"}]}}),
            Event.new(%{author: "multi", content: %{parts: [%{text: "second"}]}})
          ]
        end
      )

      runner = Runner.new(app_name: "test_multi", agent: agent)
      events = Runner.run(runner, "user1", "s_multi_#{System.unique_integer([:positive])}", "go")

      assert length(events) == 2
      assert Enum.map(events, &Event.text/1) == ["first", "second"]
    end
  end

  # ---------------------------------------------------------------------------
  # Before-Agent Callback Tests
  # ---------------------------------------------------------------------------

  describe "before_agent callbacks" do
    test "noop callback passes through, agent still runs" do
      ADK.LLM.Mock.set_responses(["from agent"])

      agent = LlmAgent.new(name: "bot", model: "mock", instruction: "hi")
      runner = Runner.new(app_name: "test_noop_before", agent: agent)
      events = Runner.run(runner, "u1", "s_nb_#{System.unique_integer([:positive])}", "hi",
        callbacks: [NoopBeforeAgent])

      texts = Enum.map(events, &Event.text/1) |> Enum.filter(& &1)
      assert "from agent" in texts
    end

    test "halt callback bypasses agent execution" do
      agent = LlmAgent.new(name: "bot", model: "mock", instruction: "hi")
      runner = Runner.new(app_name: "test_halt_before", agent: agent)
      events = Runner.run(runner, "u1", "s_hb_#{System.unique_integer([:positive])}", "hi",
        callbacks: [HaltBeforeAgent])

      assert length(events) == 1
      assert Event.text(hd(events)) == "halted by before_agent"
    end
  end

  # ---------------------------------------------------------------------------
  # After-Agent Callback Tests
  # ---------------------------------------------------------------------------

  describe "after_agent callbacks" do
    test "noop after callback returns events unchanged" do
      ADK.LLM.Mock.set_responses(["original"])

      agent = LlmAgent.new(name: "bot", model: "mock", instruction: "hi")
      runner = Runner.new(app_name: "test_noop_after", agent: agent)
      events = Runner.run(runner, "u1", "s_na_#{System.unique_integer([:positive])}", "hi",
        callbacks: [NoopAfterAgent])

      texts = Enum.map(events, &Event.text/1) |> Enum.filter(& &1)
      assert "original" in texts
    end

    test "append after callback adds an event" do
      ADK.LLM.Mock.set_responses(["original"])

      agent = LlmAgent.new(name: "bot", model: "mock", instruction: "hi")
      runner = Runner.new(app_name: "test_append_after", agent: agent)
      events = Runner.run(runner, "u1", "s_aa_#{System.unique_integer([:positive])}", "hi",
        callbacks: [AppendAfterAgent])

      texts = Enum.map(events, &Event.text/1) |> Enum.filter(& &1)
      assert "original" in texts
      assert "appended by after_agent" in texts
    end
  end

  # ---------------------------------------------------------------------------
  # Callback Chain Tests
  # ---------------------------------------------------------------------------

  describe "callback chains" do
    test "before_agent chain: first halt wins, subsequent skipped" do
      agent = LlmAgent.new(name: "bot", model: "mock", instruction: "hi")
      runner = Runner.new(app_name: "test_chain", agent: agent)
      events = Runner.run(runner, "u1", "s_ch_#{System.unique_integer([:positive])}", "hi",
        callbacks: [HaltBeforeAgentA, HaltBeforeAgentB])

      assert length(events) == 1
      assert Event.text(hd(events)) == "halted by A"
      # B never ran
      refute Enum.any?(events, &(Event.text(&1) == "halted by B"))
    end

    test "before_agent chain: continue then halt" do
      agent = LlmAgent.new(name: "bot", model: "mock", instruction: "hi")
      runner = Runner.new(app_name: "test_chain2", agent: agent)
      events = Runner.run(runner, "u1", "s_ch2_#{System.unique_integer([:positive])}", "hi",
        callbacks: [ContinueBeforeAgent, HaltBeforeAgentA])

      assert length(events) == 1
      assert Event.text(hd(events)) == "halted by A"
    end

    test "before_agent chain: all continue, agent runs" do
      ADK.LLM.Mock.set_responses(["from agent"])

      agent = LlmAgent.new(name: "bot", model: "mock", instruction: "hi")
      runner = Runner.new(app_name: "test_chain3", agent: agent)
      events = Runner.run(runner, "u1", "s_ch3_#{System.unique_integer([:positive])}", "hi",
        callbacks: [ContinueBeforeAgent, NoopBeforeAgent])

      texts = Enum.map(events, &Event.text/1) |> Enum.filter(& &1)
      assert "from agent" in texts
    end

    test "after_agent chain: multiple callbacks thread events" do
      ADK.LLM.Mock.set_responses(["original"])

      agent = LlmAgent.new(name: "bot", model: "mock", instruction: "hi")
      runner = Runner.new(app_name: "test_after_chain", agent: agent)
      events = Runner.run(runner, "u1", "s_ac_#{System.unique_integer([:positive])}", "hi",
        callbacks: [AppendAfterAgentA, AppendAfterAgentB])

      texts = Enum.map(events, &Event.text/1) |> Enum.filter(& &1)
      assert "original" in texts
      assert "from A" in texts
      assert "from B" in texts
    end
  end

  # ---------------------------------------------------------------------------
  # Callback module-level unit tests (ADK.Callback.run_before/run_after)
  # ---------------------------------------------------------------------------

  describe "ADK.Callback.run_before/3" do
    test "returns {:cont, ctx} when all callbacks continue" do
      ctx = %{agent: nil, context: nil}
      assert {:cont, ^ctx} = ADK.Callback.run_before([ContinueBeforeAgent, NoopBeforeAgent], :before_agent, ctx)
    end

    test "returns {:halt, events} on first halter" do
      ctx = %{agent: nil, context: nil}
      assert {:halt, [event]} = ADK.Callback.run_before([HaltBeforeAgentA, HaltBeforeAgentB], :before_agent, ctx)
      assert Event.text(event) == "halted by A"
    end

    test "empty callback list returns {:cont, ctx}" do
      ctx = %{agent: nil, context: nil}
      assert {:cont, ^ctx} = ADK.Callback.run_before([], :before_agent, ctx)
    end
  end

  describe "ADK.Callback.run_after/4" do
    test "threads events through all after callbacks" do
      ctx = %{agent: nil, context: nil}
      initial = [Event.new(%{author: "agent", content: %{parts: [%{text: "start"}]}})]
      result = ADK.Callback.run_after([AppendAfterAgentA, AppendAfterAgentB], :after_agent, initial, ctx)

      texts = Enum.map(result, &Event.text/1)
      assert "start" in texts
      assert "from A" in texts
      assert "from B" in texts
      assert length(result) == 3
    end

    test "empty callback list returns events unchanged" do
      ctx = %{agent: nil, context: nil}
      events = [Event.new(%{author: "a", content: %{parts: [%{text: "x"}]}})]
      assert ^events = ADK.Callback.run_after([], :after_agent, events, ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Agent Protocol Tests
  # ---------------------------------------------------------------------------

  describe "ADK.Agent protocol" do
    test "name/1 works for LlmAgent" do
      agent = LlmAgent.new(name: "test_agent", model: "mock", instruction: "hi")
      assert ADK.Agent.name(agent) == "test_agent"
    end

    test "name/1 works for Custom agent" do
      agent = Custom.new(name: "custom_agent", run_fn: fn _, _ -> [] end)
      assert ADK.Agent.name(agent) == "custom_agent"
    end

    test "sub_agents/1 returns sub-agents" do
      child = LlmAgent.new(name: "child", model: "mock", instruction: "c")
      parent = LlmAgent.new(name: "parent", model: "mock", instruction: "p", sub_agents: [child])
      subs = ADK.Agent.sub_agents(parent)
      assert length(subs) == 1
      assert ADK.Agent.name(hd(subs)) == "child"
    end

    test "sub_agents/1 returns empty list for leaf agent" do
      agent = LlmAgent.new(name: "leaf", model: "mock", instruction: "l")
      assert ADK.Agent.sub_agents(agent) == []
    end

    test "description/1 returns description" do
      agent = LlmAgent.new(name: "a", model: "mock", instruction: "i", description: "desc here")
      assert ADK.Agent.description(agent) == "desc here"
    end
  end
end
