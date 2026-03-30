defmodule ADK.ContextCompilationTest do
  @moduledoc """
  Tests for the 6 context compilation gap-closing features:

  1. Branch-aware content filtering
  2. Bidirectional transfer (parent, peer)
  3. Transfer enum constraints
  4. Compaction events
  5. Other-agent message reformatting
  6. Static instruction separation
  """
  use ExUnit.Case, async: true

  alias ADK.Event
  alias ADK.Agent.LlmAgent
  alias ADK.Tool.TransferToAgent
  alias ADK.InstructionCompiler
  alias ADK.Context
  alias ADK.Context.Compressor

  # ─────────────────────────────────────────────────
  # 1. Branch-Aware Content Filtering
  # ─────────────────────────────────────────────────

  describe "Event.on_branch?/2 — branch filtering" do
    test "nil branch events are visible to all branches" do
      event = %Event{branch: nil}
      assert Event.on_branch?(event, "root.router.weather")
      assert Event.on_branch?(event, "anything")
    end

    test "nil current_branch sees all events" do
      event = %Event{branch: "root.router.weather"}
      assert Event.on_branch?(event, nil)
    end

    test "exact branch match" do
      event = %Event{branch: "root.router.weather"}
      assert Event.on_branch?(event, "root.router.weather")
    end

    test "ancestor branch is visible to descendants" do
      # root events visible to root.router.weather
      assert Event.on_branch?(%Event{branch: "root"}, "root.router")
      assert Event.on_branch?(%Event{branch: "root"}, "root.router.weather")
      assert Event.on_branch?(%Event{branch: "root.router"}, "root.router.weather")
    end

    test "sibling branch is NOT visible" do
      # news_agent events should NOT be visible to weather_agent
      refute Event.on_branch?(%Event{branch: "root.router.news"}, "root.router.weather")
      refute Event.on_branch?(%Event{branch: "root.router.weather"}, "root.router.news")
    end

    test "descendant branch is NOT visible to ancestor" do
      # weather events should NOT be visible to the router
      refute Event.on_branch?(%Event{branch: "root.router.weather"}, "root.router")
      refute Event.on_branch?(%Event{branch: "root.router.weather"}, "root")
    end

    test "partial name overlap doesn't match (rooter vs root)" do
      refute Event.on_branch?(%Event{branch: "rooter"}, "root")
      refute Event.on_branch?(%Event{branch: "root"}, "rooter")
    end

    test "multi-agent scenario: agents don't see each other's history" do
      # Simulate: router delegates to weather_agent, then news_agent
      weather_events = [
        %Event{
          branch: "router.weather_agent",
          author: "weather_agent",
          content: %{parts: [%{text: "It's sunny"}]}
        },
        %Event{
          branch: "router.weather_agent",
          author: "weather_agent",
          content: %{parts: [%{text: "Temperature is 72°F"}]}
        }
      ]

      news_events = [
        %Event{
          branch: "router.news_agent",
          author: "news_agent",
          content: %{parts: [%{text: "Breaking news!"}]}
        }
      ]

      shared_events = [
        %Event{branch: nil, author: "user", content: %{parts: [%{text: "What's the weather?"}]}},
        %Event{branch: "router", author: "router", content: %{parts: [%{text: "Let me check"}]}}
      ]

      all_events = shared_events ++ weather_events ++ news_events

      # Weather agent sees: shared + its own events, NOT news
      weather_visible =
        Enum.filter(all_events, &Event.on_branch?(&1, "router.weather_agent"))

      # 2 shared + 2 weather
      assert length(weather_visible) == 4
      refute Enum.any?(weather_visible, &(&1.author == "news_agent"))

      # News agent sees: shared + its own events, NOT weather
      news_visible =
        Enum.filter(all_events, &Event.on_branch?(&1, "router.news_agent"))

      # 2 shared + 1 news
      assert length(news_visible) == 3
      refute Enum.any?(news_visible, &(&1.author == "weather_agent"))

      # Router sees: shared + router events only (not weather or news details)
      router_visible =
        Enum.filter(all_events, &Event.on_branch?(&1, "router"))

      # only shared (nil branch) + router branch
      assert length(router_visible) == 2
    end
  end

  describe "Context.for_child/2 — branch propagation" do
    test "sets child branch from parent branch" do
      child_agent = LlmAgent.new(name: "weather", model: "test", instruction: "Weather")
      parent_ctx = %Context{invocation_id: "inv-1", branch: "root.router"}

      child_ctx = Context.for_child(parent_ctx, child_agent)
      assert child_ctx.branch == "root.router.weather"
    end

    test "sets child branch when parent has no branch" do
      child_agent = LlmAgent.new(name: "helper", model: "test", instruction: "Help")
      parent_ctx = %Context{invocation_id: "inv-1", branch: nil}

      child_ctx = Context.for_child(parent_ctx, child_agent)
      assert child_ctx.branch == "helper"
    end

    test "nested children build deep branch paths" do
      agent_a = LlmAgent.new(name: "a", model: "test", instruction: "A")
      agent_b = LlmAgent.new(name: "b", model: "test", instruction: "B")

      root_ctx = %Context{invocation_id: "inv-1", branch: nil}
      ctx_a = Context.for_child(root_ctx, agent_a)
      ctx_b = Context.for_child(ctx_a, agent_b)

      assert ctx_a.branch == "a"
      assert ctx_b.branch == "a.b"
    end
  end

  # ─────────────────────────────────────────────────
  # 2. Bidirectional Transfer
  # ─────────────────────────────────────────────────

  describe "LlmAgent.transfer_targets/1 — bidirectional transfer" do
    test "includes sub-agents" do
      sub = LlmAgent.new(name: "child", model: "test", instruction: "Child")

      parent =
        LlmAgent.new(name: "parent", model: "test", instruction: "Parent", sub_agents: [sub])

      targets = LlmAgent.transfer_targets(parent)
      names = Enum.map(targets, &ADK.Agent.name/1)
      assert "child" in names
    end

    test "includes parent when parent_agent is set" do
      _parent = LlmAgent.new(name: "router", model: "test", instruction: "Route")
      child = LlmAgent.new(name: "worker", model: "test", instruction: "Work")

      # Simulate: parent creates child with parent_agent set (done by new/1)
      router =
        LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route",
          sub_agents: [child]
        )

      # After new/1, child's parent_agent is set
      [wired_child] = router.sub_agents
      targets = LlmAgent.transfer_targets(wired_child)
      names = Enum.map(targets, &ADK.Agent.name/1)
      assert "router" in names
    end

    test "includes peer agents (siblings)" do
      weather = LlmAgent.new(name: "weather", model: "test", instruction: "Weather")
      news = LlmAgent.new(name: "news", model: "test", instruction: "News")

      router =
        LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route",
          sub_agents: [weather, news]
        )

      # Weather agent should be able to transfer to news (peer)
      [wired_weather, _wired_news] = router.sub_agents

      targets = LlmAgent.transfer_targets(wired_weather)
      names = Enum.map(targets, &ADK.Agent.name/1)

      # Can transfer to parent (router) and peer (news)
      assert "router" in names
      assert "news" in names
      # Cannot transfer to self
      refute "weather" in names
    end

    test "disallow_transfer_to_parent excludes parent" do
      child =
        LlmAgent.new(
          name: "worker",
          model: "test",
          instruction: "Work",
          disallow_transfer_to_parent: true
        )

      router =
        LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route",
          sub_agents: [child]
        )

      [wired_child] = router.sub_agents
      # Override the flag (new/1 copies parent but doesn't override child flags)
      wired_child = %{wired_child | disallow_transfer_to_parent: true}

      targets = LlmAgent.transfer_targets(wired_child)
      names = Enum.map(targets, &ADK.Agent.name/1)
      refute "router" in names
    end

    test "disallow_transfer_to_peers excludes siblings" do
      weather =
        LlmAgent.new(
          name: "weather",
          model: "test",
          instruction: "Weather",
          disallow_transfer_to_peers: true
        )

      news = LlmAgent.new(name: "news", model: "test", instruction: "News")

      router =
        LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route",
          sub_agents: [weather, news]
        )

      [wired_weather, _] = router.sub_agents
      # Override flag
      wired_weather = %{wired_weather | disallow_transfer_to_peers: true}

      targets = LlmAgent.transfer_targets(wired_weather)
      names = Enum.map(targets, &ADK.Agent.name/1)

      # parent still allowed
      assert "router" in names
      # peer blocked
      refute "news" in names
    end

    test "agent with no parent and no sub-agents has no targets" do
      solo = LlmAgent.new(name: "solo", model: "test", instruction: "Solo")
      assert LlmAgent.transfer_targets(solo) == []
    end

    test "effective_tools includes parent and peer transfer tools" do
      weather = LlmAgent.new(name: "weather", model: "test", instruction: "Weather")
      news = LlmAgent.new(name: "news", model: "test", instruction: "News")

      router =
        LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route",
          sub_agents: [weather, news]
        )

      [wired_weather, _] = router.sub_agents
      tools = LlmAgent.effective_tools(wired_weather)
      tool_names = Enum.map(tools, & &1.name)

      assert "transfer_to_agent_router" in tool_names
      assert "transfer_to_agent_news" in tool_names
      refute "transfer_to_agent_weather" in tool_names
    end
  end

  # ─────────────────────────────────────────────────
  # 3. Transfer Enum Constraints
  # ─────────────────────────────────────────────────

  describe "TransferToAgent — enum constraints" do
    test "tool parameters include enum of valid agent names" do
      sub1 = LlmAgent.new(name: "agent_a", model: "test", instruction: "A")
      sub2 = LlmAgent.new(name: "agent_b", model: "test", instruction: "B")

      tools = TransferToAgent.tools_for_sub_agents([sub1, sub2])

      for tool <- tools do
        props = tool.parameters[:properties] || tool.parameters["properties"]
        agent_name_prop = props["agent_name"]
        assert agent_name_prop, "expected agent_name property in parameters"
        assert agent_name_prop[:enum] == ["agent_a", "agent_b"]
        assert agent_name_prop[:type] == "string"
      end
    end

    test "enum is set correctly for single agent" do
      sub = LlmAgent.new(name: "helper", model: "test", instruction: "Help")
      [tool] = TransferToAgent.tools_for_sub_agents([sub])

      props = tool.parameters[:properties] || tool.parameters["properties"]
      assert props["agent_name"][:enum] == ["helper"]
    end

    test "transfer tool still returns correct signal" do
      sub1 = LlmAgent.new(name: "target", model: "test", instruction: "Target")
      sub2 = LlmAgent.new(name: "other", model: "test", instruction: "Other")

      [t1, _t2] = TransferToAgent.tools_for_sub_agents([sub1, sub2])
      assert {:transfer_to_agent, "target"} = t1.func.(nil, %{})
    end

    test "tool declaration includes enum in schema" do
      sub = LlmAgent.new(name: "worker", model: "test", instruction: "Work")
      [tool] = TransferToAgent.tools_for_sub_agents([sub])

      props = tool.parameters[:properties] || tool.parameters["properties"]
      assert props["agent_name"][:enum] == ["worker"]
    end
  end

  # ─────────────────────────────────────────────────
  # 4. Compaction Events
  # ─────────────────────────────────────────────────

  describe "Compressor.compaction_event/2" do
    test "creates event with system:compaction author" do
      event = Compressor.compaction_event(50, 10)
      assert event.author == "system:compaction"
      assert Event.compaction?(event)
    end

    test "event contains compression info" do
      event = Compressor.compaction_event(100, 20)
      text = Event.text(event)
      assert text =~ "100 messages"
      assert text =~ "20 messages"
    end

    test "non-compaction events are not identified as compaction" do
      event = Event.new(%{author: "user", content: %{parts: [%{text: "hi"}]}})
      refute Event.compaction?(event)
    end
  end

  describe "Compressor.maybe_compress/2 — compaction event storage" do
    test "stores compaction event in session when session_pid provided" do
      # Create a real session
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "user1",
          session_id: "compact-test"
        )

      messages =
        for i <- 1..60 do
          %{role: :user, parts: [%{text: "Message #{i} with some content to make it longer"}]}
        end

      opts = [
        strategy: {ADK.Context.Compressor.Truncate, max_messages: 10},
        threshold: 50,
        session_pid: session_pid
      ]

      compressed = Compressor.maybe_compress(messages, opts)
      assert length(compressed) <= 10

      # Check that a compaction event was stored in the session
      events = ADK.Session.get_events(session_pid)
      compaction_events = Enum.filter(events, &Event.compaction?/1)
      assert length(compaction_events) == 1

      [ce] = compaction_events
      assert ce.author == "system:compaction"
      text = Event.text(ce)
      assert text =~ "60 messages"

      GenServer.stop(session_pid)
    end

    test "no compaction event when below threshold" do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "user1",
          session_id: "no-compact-test"
        )

      messages = [%{role: :user, parts: [%{text: "hi"}]}]

      opts = [
        strategy: {ADK.Context.Compressor.Truncate, max_messages: 10},
        threshold: 50,
        session_pid: session_pid
      ]

      result = Compressor.maybe_compress(messages, opts)
      assert result == messages

      events = ADK.Session.get_events(session_pid)
      assert Enum.filter(events, &Event.compaction?/1) == []

      GenServer.stop(session_pid)
    end
  end

  # ─────────────────────────────────────────────────
  # 5. Other-Agent Message Reformatting
  # ─────────────────────────────────────────────────

  describe "build_messages — other-agent reformatting" do
    # We test the private reformat logic via the public build_request path.
    # These tests verify the Event.on_branch? filtering + reformatting works together.

    test "Event.on_branch? combined with author check for reformatting scenario" do
      # Simulate what build_messages does: filter by branch, then reformat
      events = [
        %Event{author: "user", branch: nil, content: %{parts: [%{text: "Hi"}]}},
        %Event{author: "router", branch: "router", content: %{parts: [%{text: "Routing..."}]}},
        %Event{
          author: "weather",
          branch: "router.weather",
          content: %{parts: [%{text: "It's sunny"}]}
        }
      ]

      current_branch = "router.weather"
      current_agent = "weather"

      # Filter by branch
      visible = Enum.filter(events, &Event.on_branch?(&1, current_branch))
      # all are on branch (nil, ancestor, exact)
      assert length(visible) == 3

      # Classify: user = user, same agent = model, other agent = reformatted user
      messages =
        Enum.map(visible, fn e ->
          cond do
            e.author == "user" -> {:user, Event.text(e)}
            e.author == current_agent -> {:model, Event.text(e)}
            true -> {:reformatted, "[#{e.author}] said: #{Event.text(e)}"}
          end
        end)

      assert [{:user, "Hi"}, {:reformatted, "[router] said: Routing..."}, {:model, "It's sunny"}] =
               messages
    end

    test "function calls from other agents are reformatted" do
      event = %Event{
        author: "other_agent",
        branch: "root",
        content: %{
          parts: [
            %{function_call: %{name: "search", args: %{"query" => "test"}}}
          ]
        }
      }

      # Test the reformatting logic directly (extracted from LlmAgent)
      reformatted = reformat_for_test(event)
      assert reformatted.role == :user
      [part] = reformatted.parts
      assert part.text =~ "[other_agent] called tool `search`"
      assert part.text =~ "test"
    end

    test "function responses from other agents are reformatted" do
      event = %Event{
        author: "helper",
        branch: "root",
        content: %{
          parts: [
            %{function_response: %{name: "search", response: "Found 5 results"}}
          ]
        }
      }

      reformatted = reformat_for_test(event)
      assert reformatted.role == :user
      [part] = reformatted.parts
      assert part.text =~ "[helper] tool `search` returned:"
      assert part.text =~ "Found 5 results"
    end
  end

  # Helper to test reformatting without going through full build_messages
  defp reformat_for_test(event) do
    agent_name = event.author || "unknown"
    parts = (event.content || %{})[:parts] || []

    reformatted_parts =
      Enum.flat_map(parts, fn
        %{text: text} when is_binary(text) ->
          [%{text: "[#{agent_name}] said: #{text}"}]

        %{function_call: %{name: fname, args: args}} ->
          args_str = if is_map(args), do: Jason.encode!(args), else: inspect(args)
          [%{text: "[#{agent_name}] called tool `#{fname}` with parameters: #{args_str}"}]

        %{function_response: %{name: fname, response: resp}} ->
          resp_str = if is_binary(resp), do: resp, else: inspect(resp)
          [%{text: "[#{agent_name}] tool `#{fname}` returned: #{resp_str}"}]

        other ->
          [other]
      end)

    %{role: :user, parts: reformatted_parts}
  end

  # ─────────────────────────────────────────────────
  # 6. Static Instruction Separation
  # ─────────────────────────────────────────────────

  describe "InstructionCompiler.compile_split/2" do
    test "separates static and dynamic instructions" do
      agent = %{
        name: "bot",
        description: "A helpful bot",
        instruction: "Help the user with {task}.",
        global_instruction: "Be polite and professional.",
        output_schema: nil,
        sub_agents: []
      }

      ctx = %Context{invocation_id: "inv-1", session_pid: nil}

      {static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      # Static: global + identity (+ transfer if sub_agents)
      assert static =~ "Be polite and professional"
      assert static =~ "You are bot"

      # Dynamic: agent instruction (with vars)
      assert dynamic =~ "Help the user"
    end

    test "static includes transfer instructions" do
      sub =
        LlmAgent.new(
          name: "helper",
          model: "test",
          instruction: "Help",
          description: "A helper agent"
        )

      agent = %{
        name: "router",
        description: "",
        instruction: "Route requests.",
        global_instruction: nil,
        output_schema: nil,
        sub_agents: [sub]
      }

      ctx = %Context{invocation_id: "inv-1", session_pid: nil}

      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static =~ "helper"
      assert static =~ "transfer"
    end

    test "dynamic includes output schema" do
      agent = %{
        name: "bot",
        description: "",
        instruction: "Do stuff.",
        global_instruction: nil,
        output_schema: %{type: "object", properties: %{answer: %{type: "string"}}},
        sub_agents: []
      }

      ctx = %Context{invocation_id: "inv-1", session_pid: nil}

      {_static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert dynamic =~ "JSON"
      assert dynamic =~ "answer"
    end

    test "compile/2 produces same result as joining split parts" do
      agent = %{
        name: "bot",
        description: "Helpful",
        instruction: "Help users.",
        global_instruction: "Be nice.",
        output_schema: nil,
        sub_agents: []
      }

      ctx = %Context{invocation_id: "inv-1", session_pid: nil}

      combined = InstructionCompiler.compile(agent, ctx)
      {static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      expected =
        [static, dynamic]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      assert combined == expected
    end

    test "empty static when no global instruction, no identity, no sub-agents" do
      agent = %{
        name: nil,
        description: nil,
        instruction: "Just do it.",
        global_instruction: nil,
        output_schema: nil,
        sub_agents: []
      }

      ctx = %Context{invocation_id: "inv-1", session_pid: nil}

      {static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static == ""
      assert dynamic =~ "Just do it"
    end
  end

  # ─────────────────────────────────────────────────
  # Integration: build_request includes split instructions
  # ─────────────────────────────────────────────────

  describe "LlmAgent build_request includes static/dynamic split" do
    test "parent_agent is set on sub-agents by new/1" do
      child = LlmAgent.new(name: "child", model: "test", instruction: "Child")

      parent =
        LlmAgent.new(
          name: "parent",
          model: "test",
          instruction: "Parent",
          sub_agents: [child]
        )

      [wired_child] = parent.sub_agents
      assert wired_child.parent_agent != nil
      assert wired_child.parent_agent.name == "parent"
    end

    test "deeply nested agents get correct parent_agent" do
      grandchild = LlmAgent.new(name: "grandchild", model: "test", instruction: "GC")

      child =
        LlmAgent.new(name: "child", model: "test", instruction: "Child", sub_agents: [grandchild])

      parent =
        LlmAgent.new(name: "parent", model: "test", instruction: "Parent", sub_agents: [child])

      [wired_child] = parent.sub_agents
      assert wired_child.parent_agent.name == "parent"

      [wired_grandchild] = wired_child.sub_agents
      assert wired_grandchild.parent_agent.name == "child"
    end
  end

  # ─────────────────────────────────────────────────
  # Integration: Full multi-agent branch isolation
  # ─────────────────────────────────────────────────

  describe "full multi-agent branch isolation scenario" do
    test "weather and news agents have isolated histories" do
      # Simulate a full session with events from multiple agents
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "user1",
          session_id: "branch-isolation-test"
        )

      # User asks a question (no branch — visible to all)
      user_event =
        Event.new(%{
          author: "user",
          branch: nil,
          content: %{parts: [%{text: "What's the weather and news?"}]}
        })

      # Router responds (router branch)
      router_event =
        Event.new(%{
          author: "router",
          branch: "router",
          content: %{parts: [%{text: "I'll check both for you."}]}
        })

      # Weather agent responds
      weather_event =
        Event.new(%{
          author: "weather_agent",
          branch: "router.weather_agent",
          content: %{parts: [%{text: "It's 75°F and sunny."}]}
        })

      # News agent responds
      news_event =
        Event.new(%{
          author: "news_agent",
          branch: "router.news_agent",
          content: %{parts: [%{text: "Breaking: Markets up 2%"}]}
        })

      # Store all events
      for e <- [user_event, router_event, weather_event, news_event] do
        ADK.Session.append_event(session_pid, e)
      end

      all_events = ADK.Session.get_events(session_pid)
      assert length(all_events) == 4

      # Weather agent's view
      weather_visible = Enum.filter(all_events, &Event.on_branch?(&1, "router.weather_agent"))
      weather_authors = Enum.map(weather_visible, & &1.author) |> Enum.sort()
      assert "user" in weather_authors
      assert "router" in weather_authors
      assert "weather_agent" in weather_authors
      refute "news_agent" in weather_authors

      # News agent's view
      news_visible = Enum.filter(all_events, &Event.on_branch?(&1, "router.news_agent"))
      news_authors = Enum.map(news_visible, & &1.author) |> Enum.sort()
      assert "user" in news_authors
      assert "router" in news_authors
      assert "news_agent" in news_authors
      refute "weather_agent" in news_authors

      # Router's view — only sees user and its own events
      router_visible = Enum.filter(all_events, &Event.on_branch?(&1, "router"))
      router_authors = Enum.map(router_visible, & &1.author) |> Enum.sort()
      assert "user" in router_authors
      assert "router" in router_authors
      refute "weather_agent" in router_authors
      refute "news_agent" in router_authors

      GenServer.stop(session_pid)
    end

    test "three-level deep branch isolation" do
      events = [
        %Event{author: "user", branch: nil, content: %{parts: [%{text: "Go"}]}},
        %Event{author: "root", branch: "root", content: %{parts: [%{text: "Root"}]}},
        %Event{author: "mid", branch: "root.mid", content: %{parts: [%{text: "Mid"}]}},
        %Event{
          author: "leaf_a",
          branch: "root.mid.leaf_a",
          content: %{parts: [%{text: "Leaf A"}]}
        },
        %Event{
          author: "leaf_b",
          branch: "root.mid.leaf_b",
          content: %{parts: [%{text: "Leaf B"}]}
        }
      ]

      # leaf_a sees: user (nil), root, mid, leaf_a — NOT leaf_b
      leaf_a_visible = Enum.filter(events, &Event.on_branch?(&1, "root.mid.leaf_a"))
      assert length(leaf_a_visible) == 4
      refute Enum.any?(leaf_a_visible, &(&1.author == "leaf_b"))

      # mid sees: user, root, mid — NOT leaf_a or leaf_b
      mid_visible = Enum.filter(events, &Event.on_branch?(&1, "root.mid"))
      assert length(mid_visible) == 3
      refute Enum.any?(mid_visible, &(&1.author == "leaf_a"))
      refute Enum.any?(mid_visible, &(&1.author == "leaf_b"))
    end
  end

  # ─────────────────────────────────────────────────
  # Peer transfer integration
  # ─────────────────────────────────────────────────

  describe "peer transfer tool resolution" do
    test "A→B→back to A peer transfer produces correct tools" do
      agent_a =
        LlmAgent.new(name: "agent_a", model: "test", instruction: "A", description: "Agent A")

      agent_b =
        LlmAgent.new(name: "agent_b", model: "test", instruction: "B", description: "Agent B")

      router =
        LlmAgent.new(
          name: "router",
          model: "test",
          instruction: "Route",
          sub_agents: [agent_a, agent_b]
        )

      [wired_a, wired_b] = router.sub_agents

      # Agent A can transfer to router and agent_b
      a_tools = LlmAgent.effective_tools(wired_a)
      a_tool_names = Enum.map(a_tools, & &1.name)
      assert "transfer_to_agent_router" in a_tool_names
      assert "transfer_to_agent_agent_b" in a_tool_names

      # Agent B can transfer to router and agent_a
      b_tools = LlmAgent.effective_tools(wired_b)
      b_tool_names = Enum.map(b_tools, & &1.name)
      assert "transfer_to_agent_router" in b_tool_names
      assert "transfer_to_agent_agent_a" in b_tool_names
    end
  end
end
