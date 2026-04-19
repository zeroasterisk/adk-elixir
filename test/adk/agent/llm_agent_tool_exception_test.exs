defmodule ADK.Agent.LlmAgentToolExceptionTest do
  @moduledoc """
  Tests for tool exception handling and tool_call_id preservation.

  Bug: During tool execution, if a tool exhausts its retries and raises a hard exception,
  the framework's exception handling must correctly map the crash back to the specific
  tool_call_id to prevent state corruption and infinite loops.

  This test suite verifies that tool_call_id is ALWAYS preserved, even when:
  - The tool itself raises an exception
  - Callbacks raise exceptions
  - Plugins raise exceptions
  - Multiple tools are called concurrently and some fail
  """

  use ExUnit.Case, async: false

  setup do
    # Reset mock responses
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  describe "tool exception handling with tool_call_id preservation" do
    test "preserves tool_call_id when tool raises exception" do
      # Tool that raises an exception
      crashing_tool =
        ADK.Tool.FunctionTool.new(:crash_tool,
          description: "A tool that crashes",
          func: fn _ctx, _args -> raise "Tool crashed!" end,
          parameters: %{}
        )

      # LLM returns a function call with a specific ID
      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{name: "crash_tool", args: %{}, id: "call-123"}
        },
        "I see the tool had an error."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Test",
          tools: [crashing_tool]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "s1")

      ctx = %ADK.Context{
        invocation_id: "inv-1",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Run the tool"}
      }

      events = ADK.Agent.run(agent, ctx)

      # Find the function_response event
      response_event = Enum.find(events, fn e -> ADK.Event.function_responses(e) != [] end)
      assert response_event, "Expected a function_response event"

      responses = ADK.Event.function_responses(response_event)
      assert length(responses) == 1

      [response] = responses
      assert response.name == "crash_tool"
      assert response.id == "call-123", "tool_call_id must be preserved even on exception"

      # Response should contain error information
      error_content = response.response["error"]
      assert is_binary(error_content)
      assert String.contains?(error_content, "Tool crashed!")

      GenServer.stop(session_pid)
    end

    test "preserves tool_call_id for multiple tools when some crash" do
      # One working tool, one crashing tool
      working_tool =
        ADK.Tool.FunctionTool.new(:working_tool,
          description: "A working tool",
          func: fn _ctx, _args -> {:ok, "success"} end,
          parameters: %{}
        )

      crashing_tool =
        ADK.Tool.FunctionTool.new(:crashing_tool,
          description: "A crashing tool",
          func: fn _ctx, _args -> raise ArgumentError, "Bad argument!" end,
          parameters: %{}
        )

      # LLM calls both tools in one response
      ADK.LLM.Mock.set_responses([
        %{
          function_calls: [
            %{name: "working_tool", args: %{}, id: "call-001"},
            %{name: "crashing_tool", args: %{}, id: "call-002"}
          ]
        },
        "One succeeded, one failed."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "multi_tool_agent",
          model: "test",
          instruction: "Test",
          tools: [working_tool, crashing_tool]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u2", session_id: "s2")

      ctx = %ADK.Context{
        invocation_id: "inv-2",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Run both tools"}
      }

      events = ADK.Agent.run(agent, ctx)

      # Find the function_response event
      response_event = Enum.find(events, fn e -> ADK.Event.function_responses(e) != [] end)
      assert response_event, "Expected a function_response event"

      responses = ADK.Event.function_responses(response_event)
      assert length(responses) == 2

      # Check both responses have their IDs preserved
      working_response = Enum.find(responses, fn r -> r.name == "working_tool" end)
      crashing_response = Enum.find(responses, fn r -> r.name == "crashing_tool" end)

      assert working_response.id == "call-001"
      assert working_response.response["result"] == "success"

      assert crashing_response.id == "call-002"
      assert is_binary(crashing_response.response["error"])
      assert String.contains?(crashing_response.response["error"], "Bad argument!")

      GenServer.stop(session_pid)
    end

    test "preserves tool_call_id when before_tool_callback raises exception" do
      tool =
        ADK.Tool.FunctionTool.new(:test_tool,
          description: "Test tool",
          func: fn _ctx, _args -> {:ok, "result"} end,
          parameters: %{}
        )

      # Callback that crashes
      before_callback = fn _tool, _args, _ctx ->
        raise "Callback crashed!"
      end

      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{name: "test_tool", args: %{}, id: "call-callback-1"}
        },
        "Callback error handled."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "callback_test_agent",
          model: "test",
          instruction: "Test",
          tools: [tool],
          before_tool_callback: before_callback
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u3", session_id: "s3")

      ctx = %ADK.Context{
        invocation_id: "inv-3",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Run tool"}
      }

      events = ADK.Agent.run(agent, ctx)

      response_event = Enum.find(events, fn e -> ADK.Event.function_responses(e) != [] end)
      assert response_event

      responses = ADK.Event.function_responses(response_event)
      assert length(responses) == 1

      [response] = responses
      assert response.id == "call-callback-1", "tool_call_id must be preserved when callback crashes"
      assert is_binary(response.response["error"])
      assert String.contains?(response.response["error"], "Callback crashed!")

      GenServer.stop(session_pid)
    end

    test "preserves tool_call_id when after_tool_callback raises exception" do
      tool =
        ADK.Tool.FunctionTool.new(:test_tool,
          description: "Test tool",
          func: fn _ctx, _args -> {:ok, "result"} end,
          parameters: %{}
        )

      # After callback that crashes
      after_callback = fn _tool, _args, _ctx, _result ->
        raise "After callback crashed!"
      end

      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{name: "test_tool", args: %{}, id: "call-after-1"}
        },
        "After callback error handled."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "after_callback_test_agent",
          model: "test",
          instruction: "Test",
          tools: [tool],
          after_tool_callback: after_callback
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u4", session_id: "s4")

      ctx = %ADK.Context{
        invocation_id: "inv-4",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Run tool"}
      }

      events = ADK.Agent.run(agent, ctx)

      response_event = Enum.find(events, fn e -> ADK.Event.function_responses(e) != [] end)
      assert response_event

      responses = ADK.Event.function_responses(response_event)
      assert length(responses) == 1

      [response] = responses
      assert response.id == "call-after-1"
      assert is_binary(response.response["error"])
      assert String.contains?(response.response["error"], "After callback crashed!")

      GenServer.stop(session_pid)
    end

    test "error message includes tool name in exception" do
      crashing_tool =
        ADK.Tool.FunctionTool.new(:specific_tool,
          description: "Tool with specific name",
          func: fn _ctx, _args -> raise "Specific error" end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{name: "specific_tool", args: %{}, id: "call-name-1"}
        },
        "Error logged."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "name_test_agent",
          model: "test",
          instruction: "Test",
          tools: [crashing_tool]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test", user_id: "u5", session_id: "s5")

      ctx = %ADK.Context{
        invocation_id: "inv-5",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Run tool"}
      }

      events = ADK.Agent.run(agent, ctx)

      response_event = Enum.find(events, fn e -> ADK.Event.function_responses(e) != [] end)
      responses = ADK.Event.function_responses(response_event)
      [response] = responses

      error_msg = response.response["error"]
      assert String.contains?(error_msg, "specific_tool")
      assert String.contains?(error_msg, "execution failed")

      GenServer.stop(session_pid)
    end
  end
end
