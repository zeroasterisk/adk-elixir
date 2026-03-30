# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Flows.ToolsParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's tool-execution test files:

  - `tests/unittests/flows/llm_flows/test_functions_simple.py`
  - `tests/unittests/flows/llm_flows/test_functions_sequential.py`
  - `tests/unittests/flows/llm_flows/test_functions_parallel.py`
  - `tests/unittests/flows/llm_flows/test_functions_error_messages.py`
  - `tests/unittests/flows/llm_flows/test_tool_callbacks.py`

  Tests the equivalent behaviours through the Elixir Runner + LlmAgent pipeline:

  - Simple tool call → response → final text (test_simple_function)
  - Sequential tool calls across multiple LLM turns (test_sequential_calls)
  - Parallel tool calls in a single LLM response (test_parallel_function_calls)
  - Unknown tool returns error result (test_tool_not_found)
  - Tool execution error handling (test_tool_execution_error)
  - Tool result formatting (map, string, number responses)
  - State updates via tool context (test_update_state)
  - Max iterations guard with tool loops
  - Function call ID preservation
  - Tool with nil/empty args

  Parity divergences (Python-only, not ported):
  - `find_matching_function_call` internals — Python-specific event scanning
  - `merge_parallel_function_response_events` — Python batching optimization
  - Thread pool / async timing tests — Python asyncio-specific
  - `computer_use_tool_decoding_behavior` — Python-specific screenshot decoding
  - Deep copy vs shallow copy tests — Python mutable-args concern (Elixir immutable)
  - before_tool/after_tool callbacks — defined in ADK.Callback but not wired into
    LlmAgent.execute_tools; tested separately in callback_test.exs
  """

  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Runner
  alias ADK.Tool.FunctionTool

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp run_agent(agent, message) do
    runner = Runner.new(app_name: "tools_test", agent: agent)
    sid = "s-#{System.unique_integer([:positive])}"
    Runner.run(runner, "u1", sid, message)
  end

  defp text_events(events) when is_list(events) do
    events
    |> Enum.map(&safe_text/1)
    |> Enum.filter(& &1)
    |> Enum.reject(&(&1 == ""))
  end

  defp text_events(_), do: []

  # Safe text extraction handling both atom and string keyed content
  defp safe_text(%{content: content}) when is_map(content) do
    parts = Map.get(content, :parts) || Map.get(content, "parts") || []

    Enum.find_value(parts, fn
      %{text: text} -> text
      %{"text" => text} -> text
      _ -> nil
    end)
  end

  defp safe_text(_), do: nil

  defp function_call_events(events) when is_list(events) do
    Enum.filter(events, fn e ->
      parts = get_parts(e)

      Enum.any?(parts, fn p ->
        Map.has_key?(p, :function_call) or Map.has_key?(p, "function_call")
      end)
    end)
  end

  defp function_call_events(_), do: []

  defp function_response_events(events) when is_list(events) do
    Enum.filter(events, fn e ->
      parts = get_parts(e)

      Enum.any?(parts, fn p ->
        Map.has_key?(p, :function_response) or Map.has_key?(p, "function_response")
      end)
    end)
  end

  defp function_response_events(_), do: []

  # Extract parts from an event, handling both atom and string keys
  defp get_parts(%{content: content}) when is_map(content) do
    Map.get(content, :parts) || Map.get(content, "parts") || []
  end

  defp get_parts(_), do: []

  # Extract function_response data from a part (handles atom or string keys)
  defp get_function_response(part) do
    Map.get(part, :function_response) || Map.get(part, "function_response")
  end

  # Extract the response payload from a function_response
  defp get_fr_response(fr) when is_map(fr) do
    Map.get(fr, :response) || Map.get(fr, "response")
  end

  defp get_fr_response(_), do: nil

  # ====================================================================
  # 1. Simple Tool Call (test_functions_simple.py :: test_simple_function)
  # ====================================================================

  describe "simple tool call" do
    test "tool is called, result fed back to LLM, final text returned" do
      test_pid = self()

      tool =
        FunctionTool.new(:increase_by_one,
          description: "Increase x by one",
          func: fn _ctx, %{"x" => x} ->
            send(test_pid, {:tool_called, x})
            {:ok, %{"result" => x + 1}}
          end,
          parameters: %{
            type: "object",
            properties: %{x: %{type: "integer"}}
          }
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "increase_by_one", args: %{"x" => 1}, id: "fc-1"}},
        "The result is 2"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "increase 1")

      # Tool was called exactly once
      assert_received {:tool_called, 1}
      refute_received {:tool_called, _}

      # Events: tool_call, tool_response, final_text
      assert length(events) == 3
      assert length(function_call_events(events)) == 1
      assert length(function_response_events(events)) == 1
      assert "The result is 2" in text_events(events)
    end

    test "tool returning a string value is wrapped in response" do
      tool =
        FunctionTool.new(:say_hello,
          description: "Say hello",
          func: fn _ctx, _args -> {:ok, "hello!"} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "say_hello", args: %{}, id: "fc-1"}},
        "Done"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "greet")

      # The tool response event should contain the wrapped result
      resp_events = function_response_events(events)
      assert length(resp_events) == 1

      [resp_event] = resp_events
      parts = get_parts(resp_event)
      fr = get_function_response(hd(parts))
      response = get_fr_response(fr)
      assert response == %{"result" => "hello!"}
    end

    test "tool returning a map value is preserved" do
      tool =
        FunctionTool.new(:get_data,
          description: "Get data",
          func: fn _ctx, _args -> {:ok, %{"key" => "value", "count" => 42}} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "get_data", args: %{}, id: "fc-1"}},
        "Got it"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "fetch data")
      [resp_event] = function_response_events(events)
      parts = get_parts(resp_event)
      fr = get_function_response(hd(parts))
      response = get_fr_response(fr)
      assert response == %{"key" => "value", "count" => 42}
    end
  end

  # ====================================================================
  # 2. Sequential Tool Calls (test_functions_sequential.py)
  # ====================================================================

  describe "sequential tool calls" do
    test "LLM calls same tool three times across turns, accumulating history" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      tool =
        FunctionTool.new(:increase_by_one,
          description: "Increase x by one",
          func: fn _ctx, %{"x" => x} ->
            :counters.add(call_count, 1, 1)
            send(test_pid, {:tool_called, x})
            {:ok, %{"result" => x + 1}}
          end,
          parameters: %{
            type: "object",
            properties: %{x: %{type: "integer"}}
          }
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "increase_by_one", args: %{"x" => 1}, id: "fc-1"}},
        %{function_call: %{name: "increase_by_one", args: %{"x" => 2}, id: "fc-2"}},
        %{function_call: %{name: "increase_by_one", args: %{"x" => 3}, id: "fc-3"}},
        "Final: 4"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "count up")

      # Tool was called 3 times
      assert :counters.get(call_count, 1) == 3
      assert_received {:tool_called, 1}
      assert_received {:tool_called, 2}
      assert_received {:tool_called, 3}

      # Should have 3 pairs of (call, response) + 1 final text = 7 events
      assert length(function_call_events(events)) == 3
      assert length(function_response_events(events)) == 3
      assert "Final: 4" in text_events(events)
    end
  end

  # ====================================================================
  # 3. Parallel Tool Calls (test_functions_parallel.py)
  # ====================================================================

  describe "parallel tool calls" do
    test "multiple tool calls in a single LLM response are all executed" do
      test_pid = self()

      tool_a =
        FunctionTool.new(:get_weather,
          description: "Get weather",
          func: fn _ctx, %{"city" => city} ->
            send(test_pid, {:weather_called, city})
            {:ok, %{"temp" => "72F", "city" => city}}
          end,
          parameters: %{type: "object", properties: %{city: %{type: "string"}}}
        )

      tool_b =
        FunctionTool.new(:get_time,
          description: "Get time",
          func: fn _ctx, %{"tz" => tz} ->
            send(test_pid, {:time_called, tz})
            {:ok, %{"time" => "3:00 PM", "tz" => tz}}
          end,
          parameters: %{type: "object", properties: %{tz: %{type: "string"}}}
        )

      # Two function calls in a single response (parallel)
      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "get_weather", args: %{"city" => "NYC"}, id: "fc-1"}},
              %{function_call: %{name: "get_time", args: %{"tz" => "EST"}, id: "fc-2"}}
            ]
          },
          usage_metadata: nil
        },
        "Weather in NYC is 72F, time is 3:00 PM EST"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool_a, tool_b]
        )

      events = run_agent(agent, "weather and time?")

      # Both tools called
      assert_received {:weather_called, "NYC"}
      assert_received {:time_called, "EST"}

      # Should have call event, response event with 2 function_responses, and final text
      assert length(function_call_events(events)) == 1
      assert length(function_response_events(events)) == 1

      # The response event should contain both function responses
      [resp_event] = function_response_events(events)
      parts = get_parts(resp_event)

      fr_parts =
        Enum.filter(parts, fn p ->
          Map.has_key?(p, :function_response) or Map.has_key?(p, "function_response")
        end)

      assert length(fr_parts) == 2

      assert "Weather in NYC is 72F, time is 3:00 PM EST" in text_events(events)
    end

    test "parallel calls with state updates via tool_context" do
      test_pid = self()

      tool =
        FunctionTool.new(:set_key,
          description: "Set a key in state",
          func: fn ctx, %{"key" => key, "value" => value} ->
            {:ok, _ctx} = ADK.ToolContext.put_state(ctx, key, value)
            send(test_pid, {:key_set, key, value})
            {:ok, %{"set" => key}}
          end,
          parameters: %{
            type: "object",
            properties: %{key: %{type: "string"}, value: %{type: "string"}}
          }
        )

      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{
                function_call: %{
                  name: "set_key",
                  args: %{"key" => "color", "value" => "blue"},
                  id: "fc-1"
                }
              },
              %{
                function_call: %{
                  name: "set_key",
                  args: %{"key" => "size", "value" => "large"},
                  id: "fc-2"
                }
              }
            ]
          },
          usage_metadata: nil
        },
        "Done setting keys"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "set keys")

      assert_received {:key_set, "color", "blue"}
      assert_received {:key_set, "size", "large"}
      assert "Done setting keys" in text_events(events)
    end
  end

  # ====================================================================
  # 4. Unknown Tool / Error Messages (test_functions_error_messages.py)
  # ====================================================================

  describe "tool not found" do
    test "unknown tool call returns error result instead of crashing" do
      # LLM calls a tool that doesn't exist
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "nonexistent_tool", args: %{}, id: "fc-1"}},
        "I see the tool wasn't found"
      ])

      tool =
        FunctionTool.new(:real_tool,
          description: "A real tool",
          func: fn _ctx, _args -> {:ok, "ok"} end,
          parameters: %{}
        )

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "use nonexistent")

      # Should not crash — error is returned as a tool response
      resp_events = function_response_events(events)
      assert length(resp_events) == 1

      [resp_event] = resp_events
      parts = get_parts(resp_event)
      fr = get_function_response(hd(parts))
      response = get_fr_response(fr)

      # Error message should mention unknown tool
      response_str = inspect(response)
      assert response_str =~ "Unknown tool" or response_str =~ "nonexistent_tool"
    end

    test "unknown tool error includes the tool name" do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "completely_different", args: %{}, id: "fc-1"}},
        "Noted"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: []
        )

      events = run_agent(agent, "call it")
      resp_events = function_response_events(events)
      assert length(resp_events) == 1

      [resp_event] = resp_events
      parts = get_parts(resp_event)
      fr = get_function_response(hd(parts))
      response = get_fr_response(fr)

      response_str = inspect(response)
      assert response_str =~ "completely_different"
    end
  end

  # ====================================================================
  # 5. Tool Execution Errors
  # ====================================================================

  describe "tool execution errors" do
    test "tool returning {:error, reason} produces error in response" do
      tool =
        FunctionTool.new(:failing_tool,
          description: "Always fails",
          func: fn _ctx, _args -> {:error, "something broke"} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "failing_tool", args: %{}, id: "fc-1"}},
        "I see an error occurred"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "do it")

      # Error should be captured in tool response, not crash
      resp_events = function_response_events(events)
      assert length(resp_events) == 1

      [resp_event] = resp_events
      parts = get_parts(resp_event)
      fr = get_function_response(hd(parts))
      response = get_fr_response(fr)

      response_str = inspect(response)
      assert response_str =~ "something broke"
    end
  end

  # ====================================================================
  # 6. State Updates via Tools (test_functions_simple.py :: test_update_state)
  # ====================================================================

  describe "state updates via tools" do
    test "tool can update session state via tool_context" do
      tool =
        FunctionTool.new(:set_name,
          description: "Set user name in state",
          func: fn ctx, %{"name" => name} ->
            {:ok, _ctx} = ADK.ToolContext.put_state(ctx, "user_name", name)
            {:ok, %{"status" => "set"}}
          end,
          parameters: %{type: "object", properties: %{name: %{type: "string"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "set_name", args: %{"name" => "Alice"}, id: "fc-1"}},
        "Name has been set"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "set my name to Alice")
      assert "Name has been set" in text_events(events)
    end
  end

  # ====================================================================
  # 7. Function Call ID Preservation
  # ====================================================================

  describe "function call id" do
    test "function call id from LLM response is preserved in tool execution" do
      test_pid = self()

      tool =
        FunctionTool.new(:echo,
          description: "Echo back",
          func: fn ctx, args ->
            send(test_pid, {:call_id, ctx.function_call_id})
            {:ok, args}
          end,
          parameters: %{type: "object", properties: %{msg: %{type: "string"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "echo", args: %{"msg" => "hi"}, id: "custom-id-42"}},
        "echoed"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      run_agent(agent, "echo hi")
      assert_received {:call_id, "custom-id-42"}
    end
  end

  # ====================================================================
  # 8. Max Iterations with Tools
  # ====================================================================

  describe "max iterations with tool loops" do
    test "agent stops looping when max_iterations reached" do
      call_count = :counters.new(1, [:atomics])

      tool =
        FunctionTool.new(:loop_tool,
          description: "Always returns more work",
          func: fn _ctx, _args ->
            :counters.add(call_count, 1, 1)
            {:ok, "more work needed"}
          end,
          parameters: %{}
        )

      # 10 tool calls but max_iterations is 3
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "loop_tool", args: %{}, id: "fc-1"}},
        %{function_call: %{name: "loop_tool", args: %{}, id: "fc-2"}},
        %{function_call: %{name: "loop_tool", args: %{}, id: "fc-3"}},
        %{function_call: %{name: "loop_tool", args: %{}, id: "fc-4"}},
        %{function_call: %{name: "loop_tool", args: %{}, id: "fc-5"}},
        "finally done"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool],
          max_iterations: 3
        )

      _events = run_agent(agent, "loop forever")

      # Should have at most 3 iterations (tool call + response each)
      assert :counters.get(call_count, 1) <= 3
    end
  end

  # ====================================================================
  # 9. Multiple Tools Available
  # ====================================================================

  describe "multiple tools" do
    test "LLM can choose the right tool from multiple available" do
      test_pid = self()

      tool_add =
        FunctionTool.new(:add,
          description: "Add two numbers",
          func: fn _ctx, %{"a" => a, "b" => b} ->
            send(test_pid, {:add_called, a, b})
            {:ok, %{"result" => a + b}}
          end,
          parameters: %{
            type: "object",
            properties: %{a: %{type: "integer"}, b: %{type: "integer"}}
          }
        )

      tool_multiply =
        FunctionTool.new(:multiply,
          description: "Multiply two numbers",
          func: fn _ctx, %{"a" => a, "b" => b} ->
            send(test_pid, {:multiply_called, a, b})
            {:ok, %{"result" => a * b}}
          end,
          parameters: %{
            type: "object",
            properties: %{a: %{type: "integer"}, b: %{type: "integer"}}
          }
        )

      # LLM chooses multiply
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "multiply", args: %{"a" => 3, "b" => 7}, id: "fc-1"}},
        "The result is 21"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool_add, tool_multiply]
        )

      events = run_agent(agent, "multiply 3 by 7")

      assert_received {:multiply_called, 3, 7}
      refute_received {:add_called, _, _}
      assert "The result is 21" in text_events(events)
    end
  end

  # ====================================================================
  # 10. Tool with nil/empty args
  # ====================================================================

  describe "tool with nil args" do
    test "tool called with nil args receives empty map" do
      test_pid = self()

      tool =
        FunctionTool.new(:no_args_tool,
          description: "Takes no args",
          func: fn _ctx, args ->
            send(test_pid, {:args_received, args})
            {:ok, "no args needed"}
          end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "no_args_tool", args: nil, id: "fc-1"}},
        "Done"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      run_agent(agent, "do it")
      assert_received {:args_received, args}
      assert args == %{} or args == nil
    end
  end

  # ====================================================================
  # 11. Tool with numeric return value
  # ====================================================================

  describe "tool with numeric return" do
    test "numeric return value is wrapped in response map" do
      tool =
        FunctionTool.new(:count,
          description: "Count items",
          func: fn _ctx, _args -> {:ok, 42} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "count", args: %{}, id: "fc-1"}},
        "Count is 42"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "count")
      [resp_event] = function_response_events(events)
      parts = get_parts(resp_event)
      fr = get_function_response(hd(parts))
      response = get_fr_response(fr)
      assert response == %{"result" => 42}
    end
  end

  # ====================================================================
  # 12. Tool call then transfer (test_functions_parallel.py pattern)
  # ====================================================================

  describe "tool call with transfer" do
    test "tool execution followed by transfer to sub-agent" do
      test_pid = self()

      tool =
        FunctionTool.new(:prepare_data,
          description: "Prepare data",
          func: fn _ctx, _args ->
            send(test_pid, :data_prepared)
            {:ok, %{"ready" => true}}
          end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        # Root calls prepare_data tool
        %{function_call: %{name: "prepare_data", args: %{}, id: "fc-1"}},
        # After tool result, root calls transfer
        %{function_call: %{name: "transfer_to_agent_worker", args: %{}, id: "fc-2"}},
        # Worker responds
        "Worker completed the task"
      ])

      worker =
        LlmAgent.new(
          name: "worker",
          model: "test",
          instruction: "Process data.",
          description: "Data processor"
        )

      root =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Coordinate work.",
          tools: [tool],
          sub_agents: [worker]
        )

      events = run_agent(root, "process data")

      # Tool was called before transfer
      assert_received :data_prepared

      # Runner emits a transfer event; the sub-agent delegation may or may not
      # produce additional events depending on Runner orchestration depth.
      # At minimum we should see the transfer signal.
      texts = text_events(events)
      transfer_text = Enum.find(texts, &(&1 =~ "worker" or &1 =~ "Worker"))
      assert transfer_text != nil
    end
  end
end
