defmodule ADK.Tool.ExitLoopTest do
  use ExUnit.Case, async: true
  doctest ADK.Tool.ExitLoop

  alias ADK.Tool.ExitLoop
  alias ADK.Tool.FunctionTool

  describe "tool/0" do
    test "returns a FunctionTool" do
      tool = ExitLoop.tool()
      assert %FunctionTool{} = tool
    end

    test "has correct name" do
      assert ExitLoop.tool().name == "exit_loop"
    end

    test "has a description" do
      tool = ExitLoop.tool()
      assert is_binary(tool.description)
      assert String.length(tool.description) > 0
    end

    test "has parameters schema" do
      tool = ExitLoop.tool()
      assert is_map(tool.parameters)
      assert tool.parameters.type == "object"
    end

    test "calling the func with reason returns {:exit_loop, reason}" do
      tool = ExitLoop.tool()
      assert {:exit_loop, "All done"} = tool.func.(nil, %{"reason" => "All done"})
    end

    test "calling the func without reason returns default" do
      tool = ExitLoop.tool()
      assert {:exit_loop, reason} = tool.func.(nil, %{})
      assert is_binary(reason)
    end

    test "calling the func with nil args returns default" do
      tool = ExitLoop.tool()
      assert {:exit_loop, reason} = tool.func.(nil, nil)
      assert is_binary(reason)
    end
  end

  describe "exit_loop?/1" do
    test "returns true for exit_loop signal" do
      assert ExitLoop.exit_loop?({:exit_loop, "done"})
    end

    test "returns true for exit_loop with empty reason" do
      assert ExitLoop.exit_loop?({:exit_loop, ""})
    end

    test "returns false for ok tuple" do
      refute ExitLoop.exit_loop?({:ok, "result"})
    end

    test "returns false for error tuple" do
      refute ExitLoop.exit_loop?({:error, "oops"})
    end

    test "returns false for transfer_to_agent" do
      refute ExitLoop.exit_loop?({:transfer_to_agent, "some_agent"})
    end

    test "returns false for plain string" do
      refute ExitLoop.exit_loop?("exit")
    end

    test "returns false for nil" do
      refute ExitLoop.exit_loop?(nil)
    end
  end

  describe "reason/1" do
    test "extracts reason from exit_loop signal" do
      assert ExitLoop.reason({:exit_loop, "finished"}) == "finished"
    end

    test "extracts empty reason" do
      assert ExitLoop.reason({:exit_loop, ""}) == ""
    end
  end

  describe "integration with LlmAgent and LoopAgent" do
    setup do
      Process.put(:adk_mock_responses, nil)
      :ok
    end

    defp make_ctx(agent) do
      %ADK.Context{invocation_id: "test-inv", agent: agent}
    end

    test "LlmAgent calling exit_loop emits escalate event" do
      # LLM first calls exit_loop, then (not reached) a text response
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "exit_loop", args: %{"reason" => "Task done"}, id: "fc-1"}}
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "worker",
          model: "test",
          instruction: "Do task. Call exit_loop when done.",
          tools: [ExitLoop.tool()]
        )

      events = ADK.Agent.run(agent, make_ctx(agent))

      # Should have: tool_call event, escalate event
      assert length(events) == 2
      escalate_event = List.last(events)
      assert escalate_event.actions.escalate == true
      assert ADK.Event.text(escalate_event) == "Task done"
    end

    test "LoopAgent stops when LlmAgent calls exit_loop" do
      # First iteration: LLM works normally (text response)
      # Second iteration: LLM calls exit_loop
      ADK.LLM.Mock.set_responses([
        "Working on it...",
        %{function_call: %{name: "exit_loop", args: %{"reason" => "Done!"}, id: "fc-2"}}
      ])

      worker =
        ADK.Agent.LlmAgent.new(
          name: "worker",
          model: "test",
          instruction: "Work. Call exit_loop when done.",
          tools: [ExitLoop.tool()]
        )

      loop =
        ADK.Agent.LoopAgent.new(
          name: "loop",
          sub_agents: [worker],
          max_iterations: 10
        )

      events = ADK.Agent.run(loop, make_ctx(loop))

      # Iteration 1: text response (1 event)
      # Iteration 2: function_call event + escalate event (2 events), then loop stops
      assert length(events) == 3

      escalate_event = List.last(events)
      assert escalate_event.actions.escalate == true
    end

    test "exit_loop takes priority over normal tool results" do
      # Two tool calls in one response: a normal tool + exit_loop
      # exit_loop should win
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "exit_loop", args: %{"reason" => "all done"}, id: "fc-3"}}
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "agent",
          model: "test",
          instruction: "Use exit_loop.",
          tools: [ExitLoop.tool()]
        )

      events = ADK.Agent.run(agent, make_ctx(agent))

      # Must have an escalate event
      assert Enum.any?(events, fn e -> e.actions.escalate == true end)
      # Must NOT continue running more iterations
      refute Enum.any?(events, fn e ->
               is_binary(ADK.Event.text(e)) and ADK.Event.text(e) =~ "working"
             end)
    end

    test "LoopAgent without exit_loop still runs max_iterations" do
      # LLM always returns text — no exit_loop
      ADK.LLM.Mock.set_responses(["tick", "tick", "tick"])

      worker =
        ADK.Agent.LlmAgent.new(
          name: "worker",
          model: "test",
          instruction: "Keep working."
        )

      loop =
        ADK.Agent.LoopAgent.new(
          name: "loop",
          sub_agents: [worker],
          max_iterations: 3
        )

      events = ADK.Agent.run(loop, make_ctx(loop))

      assert length(events) == 3
      assert Enum.all?(events, fn e -> e.actions.escalate == false end)
    end

    test "exit_loop reason is preserved in escalate event content" do
      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{
            name: "exit_loop",
            args: %{"reason" => "Found the answer: 42"},
            id: "fc-4"
          }
        }
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "searcher",
          model: "test",
          instruction: "Search and exit.",
          tools: [ExitLoop.tool()]
        )

      events = ADK.Agent.run(agent, make_ctx(agent))
      escalate_event = Enum.find(events, fn e -> e.actions.escalate == true end)

      assert escalate_event != nil
      assert ADK.Event.text(escalate_event) == "Found the answer: 42"
    end
  end
end
