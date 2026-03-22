defmodule ADK.Agent.ToolCallbacksParityTest do
  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent

  setup do
    # Reset mock responses
    Process.put(:adk_mock_responses, nil)
    
    tool1 = ADK.Tool.FunctionTool.new(:simple_function,
      description: "A simple function.",
      func: fn _ctx, args -> %{"result" => Map.get(args, "input_str", "default")} end,
      parameters: %{
        type: "object",
        properties: %{
          "input_str" => %{type: "string"}
        }
      }
    )

    tool2 = ADK.Tool.FunctionTool.new(:simple_function_with_error,
      description: "A function that errors.",
      func: fn _ctx, _args -> {:error, "simple_function_with_error"} end,
      parameters: %{}
    )

    %{tools: [tool1, tool2]}
  end

  defp run_test(agent, responses) do
    ADK.LLM.Mock.set_responses(responses)

    {:ok, session_pid} = ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "s1")

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      session_pid: session_pid,
      agent: agent,
      user_content: %{text: "test"}
    }

    events = ADK.Agent.run(agent, ctx)
    GenServer.stop(session_pid)
    events
  end

  test "before_tool_callback halts", %{tools: tools} do
    responses = [
      %{function_call: %{name: "simple_function", args: %{"input_str" => "test"}, id: "fc-1"}},
      "response1"
    ]

    agent = LlmAgent.new(
      name: "root_agent",
      model: "mock",
      tools: tools,
      before_tool_callback: fn _tool, _args, _ctx ->
        {:halt, %{"test" => "before_tool_callback"}}
      end
    )

    events = run_test(agent, responses)

    # We expect the tool response event to contain our halted response.
    # But wait, ADK.Agent.run returns the events. The LLM Mock will receive the tool response.
    # Actually we can just check the events returned. The first event will be the final text?
    # No, LlmAgent.run returns a list of events. Let's see if the function response is in them.
    assert Enum.any?(events, fn
      %ADK.Event{content: %{parts: parts}} ->
        Enum.any?(parts, fn
          %{function_response: %{name: "simple_function", response: %{"test" => "before_tool_callback"}}} -> true
          _ -> false
        end)
      _ -> false
    end)
  end

  test "before_tool_callback noop", %{tools: tools} do
    responses = [
      %{function_call: %{name: "simple_function", args: %{"input_str" => "simple_function_call"}, id: "fc-1"}},
      "response1"
    ]

    agent = LlmAgent.new(
      name: "root_agent",
      model: "mock",
      tools: tools,
      before_tool_callback: fn _tool, _args, _ctx ->
        nil # pass through
      end
    )

    events = run_test(agent, responses)

    assert Enum.any?(events, fn
      %ADK.Event{content: %{parts: parts}} ->
        Enum.any?(parts, fn
          %{function_response: %{name: "simple_function", response: %{"result" => "simple_function_call"}}} -> true
          _ -> false
        end)
      _ -> false
    end)
  end

  test "before_tool_callback modifies tool request", %{tools: tools} do
    responses = [
      %{function_call: %{name: "simple_function", args: %{"input_str" => "original"}, id: "fc-1"}},
      "response1"
    ]

    agent = LlmAgent.new(
      name: "root_agent",
      model: "mock",
      tools: tools,
      before_tool_callback: fn _tool, args, _ctx ->
        {:cont, Map.put(args, "input_str", "modified_input")}
      end
    )

    events = run_test(agent, responses)

    assert Enum.any?(events, fn
      %ADK.Event{content: %{parts: parts}} ->
        Enum.any?(parts, fn
          %{function_response: %{name: "simple_function", response: %{"result" => "modified_input"}}} -> true
          _ -> false
        end)
      _ -> false
    end)
  end

  test "after_tool_callback modifies response", %{tools: tools} do
    responses = [
      %{function_call: %{name: "simple_function", args: %{"input_str" => "test"}, id: "fc-1"}},
      "response1"
    ]

    agent = LlmAgent.new(
      name: "root_agent",
      model: "mock",
      tools: tools,
      after_tool_callback: fn _tool, _args, _ctx, _result ->
        %{"result" => "after_tool_callback_response"}
      end
    )

    events = run_test(agent, responses)

    assert Enum.any?(events, fn
      %ADK.Event{content: %{parts: parts}} ->
        Enum.any?(parts, fn
          %{function_response: %{name: "simple_function", response: %{"result" => "after_tool_callback_response"}}} -> true
          _ -> false
        end)
      _ -> false
    end)
  end

  test "on_tool_error_callback tool not found", %{tools: tools} do
    responses = [
      %{function_call: %{name: "nonexistent_function", args: %{"input_str" => "test"}, id: "fc-1"}},
      "response1"
    ]

    agent = LlmAgent.new(
      name: "root_agent",
      model: "mock",
      tools: tools,
      on_tool_error_callback: fn tool, _args, _ctx, _err ->
        if tool.name == "nonexistent_function" do
          {:fallback, %{"result" => "on_tool_error_callback_response"}}
        else
          nil
        end
      end
    )

    events = run_test(agent, responses)

    assert Enum.any?(events, fn
      %ADK.Event{content: %{parts: parts}} ->
        Enum.any?(parts, fn
          %{function_response: %{name: "nonexistent_function", response: %{"result" => "on_tool_error_callback_response"}}} -> true
          _ -> false
        end)
      _ -> false
    end)
  end

  test "on_tool_error_callback tool returns error", %{tools: tools} do
    responses = [
      %{function_call: %{name: "simple_function_with_error", args: %{}, id: "fc-1"}},
      "response1"
    ]

    agent = LlmAgent.new(
      name: "root_agent",
      model: "mock",
      tools: tools,
      on_tool_error_callback: fn tool, _args, _ctx, _err ->
        if to_string(tool.name) == "simple_function_with_error" do
          {:fallback, %{"result" => "async_on_tool_error_callback_response"}}
        else
          nil
        end
      end
    )

    events = run_test(agent, responses)

    assert Enum.any?(events, fn
      %ADK.Event{content: %{parts: parts}} ->
        Enum.any?(parts, fn
          %{function_response: %{name: "simple_function_with_error", response: %{"result" => "async_on_tool_error_callback_response"}}} -> true
          _ -> false
        end)
      _ -> false
    end)
  end
end
